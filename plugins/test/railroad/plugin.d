module test.railroad.plugin;

import std.experimental.logger;
import pluginlib;
import voxelman.core.config;
import voxelman.core.packets;

import voxelman.edit.plugin;
import voxelman.graphics.plugin;
import voxelman.net.plugin;
import voxelman.world.clientworld;
import voxelman.world.plugin;
import voxelman.worldinteraction.plugin;

import voxelman.utils.math;
import voxelman.world.storage.coordinates;
import voxelman.world.storage.volume;

import voxelman.world.storage.blockentityaccess;
import voxelman.world.storage.worldaccess;

shared static this()
{
	pluginRegistry.regClientPlugin(new TrainsPluginClient);
	pluginRegistry.regServerPlugin(new TrainsPluginServer);
}

enum RAIL_SIZE = 4;
ivec3 railSizeVector = vec3(RAIL_SIZE, 1, RAIL_SIZE);

struct PlaceRailPacket
{
	RailPos pos;
}

struct RailPos {
	this(BlockWorldPos bwp)
	{
		vector = svec4(
			floor(cast(float)bwp.x / RAIL_SIZE),
			floor(cast(float)bwp.y),
			floor(cast(float)bwp.z / RAIL_SIZE),
			bwp.w);
	}
	ChunkWorldPos chunkPos() {
		return ChunkWorldPos(toBlockWorldPos());
	}
	BlockWorldPos toBlockWorldPos() {
		return BlockWorldPos(
			vector.x * RAIL_SIZE,
			vector.y,
			vector.z * RAIL_SIZE,
			vector.w);
	}
	Volume toBlockVolume()
	{
		return Volume(toBlockWorldPos().xyz, railSizeVector, vector.w);
	}
	svec4 vector;
}

final class TrainsPluginClient : IPlugin
{
	mixin IdAndSemverFrom!(test.railroad.plugininfo);

	NetClientPlugin connection;
	WorldInteractionPlugin worldInteraction;
	GraphicsPlugin graphics;
	ClientWorld clientWorld;
	RailPos railPos;

	override void init(IPluginManager pluginman)
	{
		auto railTool = new class ITool
		{
			this() { name = "test.entity.place_rail"; }
			override void onUpdate()
			{
				railPos = RailPos(worldInteraction.sideBlockPos);
				if (!worldInteraction.cameraInSolidBlock)
				{
					BlockWorldPos railStart = railPos.toBlockWorldPos();
					graphics.debugBatch.putCube(vec3(railStart.xyz) - cursorOffset,
						vec3(railSizeVector) + cursorOffset, Colors.green, false);
				}
			}
			override void onMainActionRelease() {
				connection.send(PlaceRailPacket(railPos));
			}
		};
		worldInteraction = pluginman.getPlugin!WorldInteractionPlugin;
		graphics = pluginman.getPlugin!GraphicsPlugin;
		clientWorld = pluginman.getPlugin!ClientWorld;

		auto editPlugin = pluginman.getPlugin!EditPlugin;
		editPlugin.registerTool(railTool);

		connection = pluginman.getPlugin!NetClientPlugin;
		connection.registerPacket!PlaceRailPacket;
	}
}

final class TrainsPluginServer : IPlugin
{
	mixin IdAndSemverFrom!(test.railroad.plugininfo);
	NetServerPlugin connection;
	ServerWorld serverWorld;

	override void init(IPluginManager pluginman)
	{
		connection = pluginman.getPlugin!NetServerPlugin;
		connection.registerPacket!PlaceRailPacket(&handlePlaceRailPacket);
		serverWorld = pluginman.getPlugin!ServerWorld;
	}

	void handlePlaceRailPacket(ubyte[] packetData, ClientId clientId)
	{
		auto packet = unpackPacket!PlaceRailPacket(packetData);
		//infof("Place rail %s", packet.pos);
		RailPos railPos = packet.pos;
		ChunkWorldPos cwp = railPos.chunkPos();
		Volume blockVolume = railPos.toBlockVolume;
		BlockEntityData beData = BlockEntityData(BlockEntityType.localBlockEntity, 1, 123);
		placeEntity(blockVolume, beData, serverWorld.worldAccess, serverWorld.entityAccess);
		connection.sendTo(serverWorld.chunkObserverManager.getChunkObservers(cwp),
			PlaceBlockEntityPacket(blockVolume, beData.storage));
	}
}