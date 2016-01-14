/**
Copyright: Copyright (c) 2015-2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.client.plugin;

import core.thread : thread_joinAll;
import core.time;
import std.experimental.logger;

import dlib.math.vector;
import dlib.math.matrix : Matrix4f;
import dlib.math.affine : translationMatrix;
import derelict.enet.enet;
import derelict.opengl3.gl3;
import derelict.imgui.imgui;
import tharsis.prof;

import netlib;
import pluginlib;
import pluginlib.pluginmanager;

import voxelman.eventdispatcher.plugin;
import voxelman.graphics.plugin;
import voxelman.gui.plugin;
import voxelman.net.plugin;
import voxelman.command.plugin;
import voxelman.block.plugin;
import voxelman.world.clientworld;

import voxelman.net.events;
import voxelman.core.packets;
import voxelman.net.packets;

import voxelman.config.configmanager;
import voxelman.input.keybindingmanager;

import voxelman.core.config;
import voxelman.core.events;
import voxelman.storage.chunk;
import voxelman.storage.coordinates;
import voxelman.storage.utils;
import voxelman.storage.worldaccess;
import voxelman.utils.math;
import voxelman.utils.textformatter;

import voxelman.client.appstatistics;
import voxelman.client.console;

//version = manualGC;
version(manualGC) import core.memory;

version = profiling;

shared static this()
{
	auto c = new ClientPlugin;
	pluginRegistry.regClientPlugin(c);
	pluginRegistry.regClientMain(&c.run);
}

auto formatDuration(Duration dur)
{
	import std.string : format;
	auto splitted = dur.split();
	return format("%s.%03s,%03s secs",
		splitted.seconds, splitted.msecs, splitted.usecs);
}

final class ClientPlugin : IPlugin
{
private:
	PluginManager pluginman;

	// Plugins
	EventDispatcherPlugin evDispatcher;
	GraphicsPlugin graphics;
	GuiPlugin guiPlugin;
	CommandPluginClient commandPlugin;
	ClientWorld clientWorld;
	NetClientPlugin connection;

public:
	AppStatistics stats;
	Console console;

	// Debug
	Profiler profiler;
	DespikerSender profilerSender;

	// Client data
	bool isRunning = false;
	bool mouseLocked;

	ConfigOption runDespikerOpt;

	// Graphics stuff
	bool isCullingEnabled = true;
	bool isConsoleShown = false;

	// IPlugin stuff
	mixin IdAndSemverFrom!(voxelman.client.plugininfo);

	override void registerResources(IResourceManagerRegistry resmanRegistry)
	{
		ConfigManager config = resmanRegistry.getResourceManager!ConfigManager;
		runDespikerOpt = config.registerOption!bool("run_despiker", false);

		KeyBindingManager keyBindingMan = resmanRegistry.getResourceManager!KeyBindingManager;
		keyBindingMan.registerKeyBinding(new KeyBinding(KeyCode.KEY_Q, "key.lockMouse", null, &onLockMouse));
		keyBindingMan.registerKeyBinding(new KeyBinding(KeyCode.KEY_C, "key.toggleCulling", null, &onToggleCulling));
		keyBindingMan.registerKeyBinding(new KeyBinding(KeyCode.KEY_GRAVE_ACCENT, "key.toggle_console", null, &onConsoleToggleKey));
	}

	override void preInit()
	{
		console.init();
	}

	override void init(IPluginManager pluginman)
	{
		clientWorld = pluginman.getPlugin!ClientWorld;
		evDispatcher = pluginman.getPlugin!EventDispatcherPlugin;
		evDispatcher.profiler = profiler;

		graphics = pluginman.getPlugin!GraphicsPlugin;
		guiPlugin = pluginman.getPlugin!GuiPlugin;

		evDispatcher.subscribeToEvent(&onPreUpdateEvent);
		evDispatcher.subscribeToEvent(&onPostUpdateEvent);
		evDispatcher.subscribeToEvent(&drawScene);
		evDispatcher.subscribeToEvent(&drawOverlay);
		evDispatcher.subscribeToEvent(&onClosePressedEvent);

		commandPlugin = pluginman.getPlugin!CommandPluginClient;
		console.messageWindow.messageHandler = &onConsoleCommand;

		connection = pluginman.getPlugin!NetClientPlugin;
	}

	override void postInit()
	{
		if (runDespikerOpt.get!bool)
			toggleProfiler();
	}

	void printDebug()
	{
		igSetNextWindowSize(ImVec2(400, 300), ImGuiSetCond_FirstUseEver);
		igSetNextWindowPos(ImVec2(0, 0), ImGuiSetCond_FirstUseEver);
		igBegin("Debug");
		with(stats) {
			igTextf("FPS: %s", fps);
			igTextf("Chunks visible/rendered %s/%s %.0f%%",
				chunksVisible, chunksRendered,
				chunksVisible ? cast(float)chunksRendered/chunksVisible*100 : 0);
			igTextf("Chunks per frame loaded: %s",
				totalLoadedChunks - lastFrameLoadedChunks);
			igTextf("Chunks total loaded: %s",
				totalLoadedChunks);
			igTextf("Vertexes %s", vertsRendered);
			igTextf("Triangles %s", trisRendered);
			vec3 pos = graphics.camera.position;
			igTextf("Pos: X %.2f, Y %.2f, Z %.2f", pos.x, pos.y, pos.z);
		}

		ChunkWorldPos chunkPos = clientWorld.chunkMan.observerPosition;
		auto regionPos = RegionWorldPos(chunkPos);
		auto localChunkPosition = ChunkRegionPos(chunkPos);
		igTextf("C: %s R: %s L: %s", chunkPos, regionPos, localChunkPosition);

		vec3 target = graphics.camera.target;
		vec2 heading = graphics.camera.heading;
		igTextf("Heading: %.2f %.2f Target: X %.2f, Y %.2f, Z %.2f",
			heading.x, heading.y, target.x, target.y, target.z);
		igTextf("Chunks to remove: %s", clientWorld.chunkMan.removeQueue.length);
		igTextf("Chunks to mesh: %s", clientWorld.chunkMan.chunkMeshMan.numMeshChunkTasks);
		igTextf("View radius: %s", clientWorld.chunkMan.viewRadius);
		igEnd();
	}

	this()
	{
		pluginman = new PluginManager;

		version(profiling)
		{
			ubyte[] storage  = new ubyte[Profiler.maxEventBytes + 20 * 1024 * 1024];
			profiler = new Profiler(storage);
		}
		profilerSender = new DespikerSender([profiler]);
	}

	void load(string[] args)
	{
		// register all plugins and managers
		import voxelman.pluginlib.plugininforeader : filterEnabledPlugins;
		foreach(p; pluginRegistry.clientPlugins.byValue.filterEnabledPlugins(args))
		{
			pluginman.registerPlugin(p);
		}

		// Actual loading sequence
		pluginman.initPlugins();
	}

	void run(string[] args)
	{
		import std.datetime : TickDuration, Clock, usecs;
		import core.thread : Thread;

		version(manualGC) GC.disable;

		load(args);
		evDispatcher.postEvent(GameStartEvent());

		TickDuration lastTime = Clock.currAppTick;
		TickDuration newTime = TickDuration.from!"seconds"(0);

		isRunning = true;
		while(isRunning)
		{
			Zone frameZone = Zone(profiler, "frame");

			newTime = Clock.currAppTick;
			double delta = (newTime - lastTime).usecs / 1_000_000.0;
			lastTime = newTime;

			{
				Zone subZone = Zone(profiler, "preUpdate");
				evDispatcher.postEvent(PreUpdateEvent(delta));
			}
			{
				Zone subZone = Zone(profiler, "update");
				evDispatcher.postEvent(UpdateEvent(delta));
			}
			{
				Zone subZone = Zone(profiler, "postUpdate");
				evDispatcher.postEvent(PostUpdateEvent(delta));
			}
			{
				Zone subZone = Zone(profiler, "render");
				evDispatcher.postEvent(RenderEvent());
			}
			{
				version(manualGC) {
					Zone subZone = Zone(profiler, "GC.collect()");
					GC.collect();
				}
			}
			{
				Zone subZone = Zone(profiler, "sleepAfterFrame");
				// time used in frame
				delta = (lastTime - Clock.currAppTick).usecs / 1_000_000.0;
				guiPlugin.fpsHelper.sleepAfterFrame(delta);
			}

			version(profiling) {
				frameZone.__dtor;
				profilerSender.update();
			}
		}
		profilerSender.reset();

		evDispatcher.postEvent(GameStopEvent());
	}

	void toggleProfiler()
	{
		if (profilerSender.sending)
			profilerSender.reset();
		else
		{
			import std.file : exists;
			if (exists(DESPIKER_PATH))
				profilerSender.startDespiker(DESPIKER_PATH);
			else
				warningf(`No despiker executable found at "%s"`, DESPIKER_PATH);
		}
	}

	void onPreUpdateEvent(ref PreUpdateEvent event)
	{
	}

	void onPostUpdateEvent(ref PostUpdateEvent event)
	{
		stats.fps = guiPlugin.fpsHelper.fps;
		stats.totalLoadedChunks = clientWorld.chunkMan.totalLoadedChunks;

		printDebug();
		stats.resetCounters();
		if (isConsoleShown)
			console.draw();
	}

	void onConsoleCommand(string command)
	{
		infof("Executing command '%s'", command);
		ExecResult res = commandPlugin.execute(command, ClientId(0));

		if (res.status == ExecStatus.notRegistered)
		{
			if (connection.isConnected)
				connection.send(CommandPacket(command));
			else
				console.lineBuffer.putfln("Unknown client command '%s', not connected to server", command);
		}
		else if (res.status == ExecStatus.error)
			console.lineBuffer.putfln("Error executing command '%s': %s", command, res.error);
		else
			console.lineBuffer.putln(command);
	}

	void onConsoleToggleKey(string)
	{
		isConsoleShown = !isConsoleShown;
	}

	void onClosePressedEvent(ref ClosePressedEvent event)
	{
		isRunning = false;
	}

	void onLockMouse(string)
	{
		mouseLocked = !mouseLocked;
		if (mouseLocked)
			guiPlugin.window.mousePosition = cast(ivec2)(guiPlugin.window.size) / 2;
	}

	void onToggleCulling(string)
	{
		isCullingEnabled = !isCullingEnabled;
	}

	void drawScene(ref Render1Event event)
	{
		Zone drawSceneZone = Zone(profiler, "drawScene");

		graphics.chunkShader.bind;
		glUniformMatrix4fv(graphics.viewLoc, 1, GL_FALSE,
			graphics.camera.cameraMatrix);
		glUniformMatrix4fv(graphics.projectionLoc, 1, GL_FALSE,
			cast(const float*)graphics.camera.perspective.arrayof);

		import dlib.geometry.aabb;
		import dlib.geometry.frustum;
		Matrix4f vp = graphics.camera.perspective * graphics.camera.cameraToClipMatrix;
		Frustum frustum;
		frustum.fromMVP(vp);

		Matrix4f modelMatrix;
		foreach(ChunkWorldPos cwp; clientWorld.chunkMan.chunkMeshMan.visibleChunks.items)
		{
			Chunk* c = clientWorld.chunkMan.getChunk(cwp);
			assert(c);
			++stats.chunksVisible;

			if (isCullingEnabled)
			{
				// Frustum culling
				ivec3 ivecMin = c.position.vector * CHUNK_SIZE;
				vec3 vecMin = vec3(ivecMin.x, ivecMin.y, ivecMin.z);
				vec3 vecMax = vecMin + CHUNK_SIZE;
				AABB aabb = boxFromMinMaxPoints(vecMin, vecMax);
				auto intersects = frustum.intersectsAABB(aabb);
				if (!intersects) continue;
			}

			modelMatrix = translationMatrix!float(c.mesh.position);
			glUniformMatrix4fv(graphics.modelLoc, 1, GL_FALSE, cast(const float*)modelMatrix.arrayof);

			c.mesh.bind;
			c.mesh.render;

			++stats.chunksRendered;
			stats.vertsRendered += c.mesh.numVertexes;
			stats.trisRendered += c.mesh.numTris;
		}

		glUniformMatrix4fv(graphics.modelLoc, 1, GL_FALSE, cast(const float*)Matrix4f.identity.arrayof);
		graphics.chunkShader.unbind;
	}

	void drawOverlay(ref Render2Event event)
	{
		//event.renderer.setColor(Color(0,0,0,1));
		//event.renderer.fillRect(Rect(guiPlugin.window.size.x/2-7, guiPlugin.window.size.y/2-1, 14, 2));
		//event.renderer.fillRect(Rect(guiPlugin.window.size.x/2-1, guiPlugin.window.size.y/2-7, 2, 14));
	}
}