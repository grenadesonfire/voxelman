/**
Copyright: Copyright (c) 2015-2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.world.serverworld;

import voxelman.log;
import std.array : empty;
import core.atomic : atomicStore, atomicLoad;
import cbor;
import netlib;
import pluginlib;
import voxelman.math;

import voxelman.core.config;
import voxelman.core.events;
import voxelman.net.events;
import voxelman.utils.compression;

import voxelman.input.keybindingmanager;
import voxelman.config.configmanager : ConfigOption, ConfigManager;
import voxelman.eventdispatcher.plugin : EventDispatcherPlugin;
import voxelman.net.plugin : NetServerPlugin;
import voxelman.session.server;
import voxelman.block.plugin;
import voxelman.blockentity.plugin;
import voxelman.dbg.plugin;
import voxelman.server.plugin : WorldSaveInternalEvent;

import voxelman.net.packets;
import voxelman.core.packets;

import voxelman.blockentity.blockentityaccess;
import voxelman.world.storage;

public import voxelman.world.worlddb : WorldDb;

struct IdMapManagerServer
{
	string[][string] idMaps;
	void regIdMap(string name, string[] mapItems)
	{
		idMaps[name] = mapItems;
	}
}

struct WorldInfo
{
	string name = DEFAULT_WORLD_NAME;
	TimestampType simulationTick;
	ivec3 spawnPosition;
}

//version = DBG_COMPR;
final class ServerWorld : IPlugin
{
private:
	EventDispatcherPlugin evDispatcher;
	NetServerPlugin connection;
	ClientManager clientMan;
	BlockPluginServer blockPlugin;
	BlockEntityServer blockEntityPlugin;

	Debugger dbg;

	ConfigOption numGenWorkersOpt;

	ubyte[] buf;
	WorldInfo worldInfo;
	auto dbKey = IoKey("voxelman.world.world_info");
	string worldFilename;

	shared bool isSaving;
	IoManager ioManager;
	WorldDb worldDb;
	PluginDataSaver pluginDataSaver;

public:
	ChunkManager chunkManager;
	ChunkProvider chunkProvider;
	ChunkObserverManager chunkObserverManager;
	DimensionManager dimMan;
	ActiveChunks activeChunks;
	IdMapManagerServer idMapManager;

	WorldAccess worldAccess;
	BlockEntityAccess entityAccess;

	mixin IdAndSemverFrom!(voxelman.world.plugininfo);

	override void registerResourceManagers(void delegate(IResourceManager) registerHandler)
	{
		ioManager = new IoManager(&loadWorld);
		registerHandler(ioManager);
	}

	override void registerResources(IResourceManagerRegistry resmanRegistry)
	{
		ConfigManager config = resmanRegistry.getResourceManager!ConfigManager;
		numGenWorkersOpt = config.registerOption!int("num_workers", 4);
		ioManager.registerWorldLoadSaveHandlers(&readWorldInfo, &writeWorldInfo);
		ioManager.registerWorldLoadSaveHandlers(&activeChunks.read, &activeChunks.write);
		ioManager.registerWorldLoadSaveHandlers(&dimMan.load, &dimMan.save);

		dbg = resmanRegistry.getResourceManager!Debugger;
	}

	override void preInit()
	{
		pluginDataSaver.stringMap = &ioManager.stringMap;
		pluginDataSaver.alloc();
		buf = new ubyte[](1024*64*4);
		chunkManager = new ChunkManager();
		worldAccess = new WorldAccess(chunkManager);
		entityAccess = new BlockEntityAccess(chunkManager);
		chunkObserverManager = new ChunkObserverManager();

		ubyte numLayers = 2;
		chunkManager.setup(numLayers);
		chunkManager.isChunkSavingEnabled = true;

		// Component connections
		chunkManager.startChunkSave = &chunkProvider.startChunkSave;
		chunkManager.pushLayer = &chunkProvider.pushLayer;
		chunkManager.endChunkSave = &chunkProvider.endChunkSave;
		chunkManager.loadChunkHandler = &chunkProvider.loadChunk;

		chunkProvider.onChunkLoadedHandler = &chunkManager.onSnapshotLoaded!LoadedChunkData;
		chunkProvider.onChunkSavedHandler = &chunkManager.onSnapshotSaved!SavedChunkData;

		chunkObserverManager.changeChunkNumObservers = &chunkManager.setExternalChunkObservers;
		chunkObserverManager.chunkObserverAdded = &onChunkObserverAdded;
		chunkObserverManager.loadQueueSpaceAvaliable = &chunkProvider.loadQueueSpaceAvaliable;

		activeChunks.loadChunk = &chunkObserverManager.addServerObserver;
		activeChunks.unloadChunk = &chunkObserverManager.removeServerObserver;

		chunkManager.onChunkLoadedHandler = &onChunkLoaded;
	}

	override void init(IPluginManager pluginman)
	{
		blockPlugin = pluginman.getPlugin!BlockPluginServer;
		clientMan = pluginman.getPlugin!ClientManager;

		evDispatcher = pluginman.getPlugin!EventDispatcherPlugin;
		evDispatcher.subscribeToEvent(&handlePreUpdateEvent);
		evDispatcher.subscribeToEvent(&handlePostUpdateEvent);
		evDispatcher.subscribeToEvent(&handleStopEvent);
		evDispatcher.subscribeToEvent(&handleClientDisconnected);
		evDispatcher.subscribeToEvent(&handleSaveEvent);
		evDispatcher.subscribeToEvent(&handleClientConnectedEvent);

		blockEntityPlugin = pluginman.getPlugin!BlockEntityServer;

		connection = pluginman.getPlugin!NetServerPlugin;
		connection.registerPacketHandler!FillBlockBoxPacket(&handleFillBlockBoxPacket);
		connection.registerPacketHandler!PlaceBlockEntityPacket(&handlePlaceBlockEntityPacket);
		connection.registerPacketHandler!RemoveBlockEntityPacket(&handleRemoveBlockEntityPacket);

		chunkProvider.init(worldDb, numGenWorkersOpt.get!uint, blockPlugin.getBlocks());
		worldDb = null;
		activeChunks.loadActiveChunks();
		worldAccess.blockInfos = blockPlugin.getBlocks();
	}

	TimestampType currentTimestamp() @property
	{
		return worldInfo.simulationTick;
	}

	private void handleSaveEvent(ref WorldSaveInternalEvent event)
	{
		if (!atomicLoad(isSaving)) {
			atomicStore(isSaving, true);
			chunkManager.save();
			foreach(saveHandler; ioManager.worldSaveHandlers) {
				saveHandler(pluginDataSaver);
			}
			chunkProvider.pushSaveHandler(&worldSaver);
		}
	}

	// executed on io thread. Stores values written into pluginDataSaver.
	private void worldSaver(WorldDb wdb)
	{
		foreach(ubyte[16] key, ubyte[] data; pluginDataSaver) {
			wdb.put(key, data);
		}
		pluginDataSaver.reset();
		atomicStore(isSaving, false);
	}

	private void loadWorld(string _worldFilename)
	{
		worldFilename = _worldFilename;
		worldDb = new WorldDb;
		worldDb.open(_worldFilename);

		worldDb.beginTxn();
		scope(exit) worldDb.abortTxn();

		auto dataLoader = PluginDataLoader(&ioManager.stringMap, worldDb);
		foreach(loadHandler; ioManager.worldLoadHandlers) {
			loadHandler(dataLoader);
		}
	}

	private void readWorldInfo(ref PluginDataLoader loader)
	{
		import std.path : absolutePath, buildNormalizedPath;
		ubyte[] data = loader.readEntryRaw(dbKey);
		if (!data.empty) {
			worldInfo = decodeCborSingleDup!WorldInfo(data);
			infof("Loading world %s", worldFilename.absolutePath.buildNormalizedPath);
		} else {
			infof("Creating world %s", worldFilename.absolutePath.buildNormalizedPath);
		}
	}

	private void writeWorldInfo(ref PluginDataSaver saver)
	{
		saver.writeEntryEncoded(dbKey, worldInfo);
	}

	private void handlePreUpdateEvent(ref PreUpdateEvent event)
	{
		++worldInfo.simulationTick;
		chunkProvider.update();
		chunkObserverManager.update();
	}

	private void handlePostUpdateEvent(ref PostUpdateEvent event)
	{
		chunkManager.commitSnapshots(currentTimestamp);
		sendChanges(worldAccess.blockChanges);
		worldAccess.blockChanges = null;

		import voxelman.world.gen.generators;
		import core.atomic;
		dbg.setVar("cacheHits", atomicLoad(cache_hits));
		dbg.setVar("cacheMiss", atomicLoad(cache_misses));
	}

	private void handleStopEvent(ref GameStopEvent event)
	{
		while(atomicLoad(isSaving))
		{
			import core.thread : Thread;
			Thread.yield();
		}
		chunkProvider.stop();
		pluginDataSaver.free();
	}

	private void onChunkObserverAdded(ChunkWorldPos cwp, ClientId clientId)
	{
		sendChunk(clientId, cwp);
	}

	private void handleClientConnectedEvent(ref ClientConnectedEvent event)
	{
		foreach(key, idmap; idMapManager.idMaps)
		{
			connection.sendTo(event.clientId, IdMapPacket(key, idmap));
		}
	}

	private void handleClientDisconnected(ref ClientDisconnectedEvent event)
	{
		chunkObserverManager.removeObserver(event.clientId);
	}

	private void onChunkLoaded(ChunkWorldPos cwp)
	{
		sendChunk(chunkObserverManager.getChunkObservers(cwp), cwp);
	}

	private void sendChunk(C)(C clients, ChunkWorldPos cwp)
	{
		import voxelman.core.packets : ChunkDataPacket;

		if (!chunkManager.isChunkLoaded(cwp)) return;
		BlockData[8] layerBuf;
		size_t compressedSize;

		ubyte numChunkLayers;
		foreach(ubyte layerId; 0..chunkManager.numLayers)
		{
			auto layer = chunkManager.getChunkSnapshot(cwp, layerId);
			if (layer.isNull) continue;

			//if (layer.dataLength == 5 && layerId == 1)
			//	infof("CM Loaded %s %s", cwp, layer.type);
			if (cwp == ChunkWorldPos(-17, 1, 69, 0))
				infof("Send %s %s", cwp, layer);
			if (layerId == 0 && cwp == ChunkWorldPos(-17, 1, 69, 0))
			{
				if (layer.type == StorageType.fullArray)
				{
					auto array = layer.getArray!ubyte;
					infof("Send %s %s\n(%(%02x%))", cwp, array.length, array);
				}
			}

			version(DBG_COMPR)if (layer.type != StorageType.uniform)
			{
				ubyte[] compactBlocks = layer.getArray!ubyte;
				infof("Send %s %s %s\n(%(%02x%))", cwp, compactBlocks.ptr, compactBlocks.length, cast(ubyte[])compactBlocks);
			}

			BlockData bd = toBlockData(layer, layerId);
			if (layer.type == StorageType.fullArray)
			{
				ubyte[] compactBlocks = compressLayerData(layer.getArray!ubyte, buf[compressedSize..$]);
				compressedSize += compactBlocks.length;
				bd.blocks = compactBlocks;
			}
			layerBuf[numChunkLayers] = bd;

			++numChunkLayers;
		}

		connection.sendTo(clients, ChunkDataPacket(cwp.ivector, layerBuf[0..numChunkLayers]));
	}

	private void sendChanges(BlockChange[][ChunkWorldPos] changes)
	{
		import voxelman.core.packets : MultiblockChangePacket;
		foreach(pair; changes.byKeyValue)
		{
			connection.sendTo(
				chunkObserverManager.getChunkObservers(pair.key),
				MultiblockChangePacket(pair.key.ivector, pair.value));
		}
	}

	private void handleFillBlockBoxPacket(ubyte[] packetData, ClientId clientId)
	{
		import voxelman.core.packets : FillBlockBoxPacket;
		if (clientMan.isSpawned(clientId))
		{
			auto packet = unpackPacketNoDup!FillBlockBoxPacket(packetData);
			// TODO send to observers only.
			worldAccess.fillBox(packet.box, packet.blockId);
			connection.sendToAll(packet);
		}
	}

	private void handlePlaceBlockEntityPacket(ubyte[] packetData, ClientId clientId)
	{
		auto packet = unpackPacket!PlaceBlockEntityPacket(packetData);
		placeEntity(
			packet.box, packet.data,
			worldAccess, entityAccess);

		// TODO send to observers only.
		connection.sendToAll(packet);
	}

	private void handleRemoveBlockEntityPacket(ubyte[] packetData, ClientId peer)
	{
		auto packet = unpackPacket!RemoveBlockEntityPacket(packetData);
		WorldBox vol = removeEntity(BlockWorldPos(packet.blockPos),
			blockEntityPlugin.blockEntityInfos, worldAccess, entityAccess, /*AIR*/1);
		//infof("Remove entity at %s", vol);

		connection.sendToAll(packet);
	}
}
