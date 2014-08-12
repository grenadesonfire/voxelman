/**
Copyright: Copyright (c) 2014 Andrey Penechko.
License: a$(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/

module voxelman.app;

import std.stdio : writeln;
import std.string : format;
import std.parallelism;
import std.concurrency;
import std.datetime;
import core.atomic;

import dlib.math.matrix;
import dlib.math.affine;

import anchovy.graphics.windows.glfwwindow;
import anchovy.gui;
import anchovy.gui.application.application;
import anchovy.gui.databinding.list;

import voxelman.fpscontroller;
import voxelman.camera;

class VoxelApplication : Application!GlfwWindow
{
	__gshared ChunkMan chunkMan;
	uvec3 viewSize;
	ulong chunksRendered;
	ulong vertsRendered;
	ulong trisRendered;

	ShaderProgram chunkShader;

	FpsController fpsController;
	bool mouseLocked;

	Widget debugInfo;

	this(uvec2 windowSize, string caption)
	{
		super(windowSize, caption);
	}

	void addHideHandler(string frameId)
	{
		auto frame = context.getWidgetById(frameId);
		Widget closeButton = frame["subwidgets"].get!(Widget[string])["close"];
		closeButton.addEventHandler(delegate bool(Widget widget, PointerClickEvent event){
			frame["isVisible"] = false;
			return true;
		});
	}

	void setupFrameShowButton(string buttonId, string frameId)
	{
		auto frame = context.getWidgetById(frameId);
		context.getWidgetById(buttonId).addEventHandler(delegate bool(Widget widget, PointerClickEvent event){
			frame["isVisible"] = true;
			return true;
		});
	}

	override void load(in string[] args)
	{
		writeln("---------------------- System info ----------------------");
		foreach(item; getHardwareInfo())
			writeln(item);
		writeln("---------------------------------------------------------\n");

		fpsHelper.limitFps = false;

		// Setup rendering

		clearColor = Color(255, 255, 255);
		renderer.setClearColor(clearColor);

		fpsController = new FpsController;
		//fpsController.move(vec3(0, 4, 64));
		fpsController.camera.sensivity = 0.4;

		// Setupr shaders

		string vShader = cast(string)read("perspective.vert");		
		string fShader = cast(string)read("colored.frag");		
		chunkShader = new ShaderProgram(vShader, fShader);

		if(!chunkShader.compile())
		{
			writeln(chunkShader.errorLog);
		}
		else
		{
			writeln("Shaders compiled successfully");
		}

		chunkShader.bind;
			modelToWorldMatrixLoc = glGetUniformLocation( chunkShader.program, "modelToWorldMatrix" );//model transformation
			worldToCameraMatrixLoc = glGetUniformLocation( chunkShader.program, "worldToCameraMatrix" );//camera trandformation
			cameraToClipMatrixLoc = glGetUniformLocation( chunkShader.program, "cameraToClipMatrix" );//perspective	

			glUniformMatrix4fv(modelToWorldMatrixLoc, 1, GL_FALSE, cast(const float*)Matrix4f.identity.arrayof);
			glUniformMatrix4fv(worldToCameraMatrixLoc, 1, GL_FALSE, cast(const float*)fpsController.cameraMatrix);
			glUniformMatrix4fv(cameraToClipMatrixLoc, 1, GL_FALSE, cast(const float*)fpsController.camera.perspective.arrayof);
		chunkShader.unbind;

		// Bind events

		aggregator.window.windowResized.connect(&windowResized);
		aggregator.window.keyReleased.connect(&keyReleased);

		// ----------------------------- Creating widgets -----------------------------
		templateManager.parseFile("voxelman.sdl");

		auto mainLayer = context.createWidget("mainLayer");
		context.addRoot(mainLayer);

		auto frameLayer = context.createWidget("frameLayer");
		context.addRoot(frameLayer);

		// Frames
		addHideHandler("infoFrame");
		addHideHandler("settingsFrame");

		setupFrameShowButton("showInfo", "infoFrame");
		setupFrameShowButton("showSettings", "settingsFrame");

		debugInfo = context.getWidgetById("debugInfo");
		foreach(i; 0..10) context.createWidget("label", debugInfo);

		writeln("\n----------------------------- Load end -----------------------------\n");

		// ----------------------------- init chunks ---------------------------

		chunkMan.init();
		chunkMan.updateObserverPosition(fpsController.camera.position);
	}

	override void unload()
	{
		chunkMan.stop();
	}

	ulong lastFrameLoadedChunks = 0;
	override void update(double dt)
	{
		fpsHelper.update(dt);

		printDebug();

		timerManager.updateTimers(window.elapsedTime);
		context.update(dt);

		updateController(dt);
		chunkMan.updateObserverPosition(fpsController.camera.position);
		chunkMan.update();
	}

	void printDebug()
	{
		// Print debug info
		auto lines = debugInfo.getPropertyAs!("children", Widget[]);

		lines[ 0]["text"] = format("FPS: %s", fpsHelper.fps).to!dstring;
		lines[ 1]["text"] = format("Chunks %s", chunksRendered).to!dstring;
		chunksRendered = 0;

		ulong chunksLoaded = totalLoadedChunks;
		lines[ 2]["text"] = format("Chunks per frame loaded: %s",
			chunksLoaded - lastFrameLoadedChunks).to!dstring;
		lines[ 3]["text"] = format("Chunks total loaded: %s",
			chunksLoaded).to!dstring;
		lastFrameLoadedChunks = chunksLoaded;

		lines[ 4]["text"] = format("Vertexes %s", vertsRendered).to!dstring;
		vertsRendered = 0;
		lines[ 5]["text"] = format("Triangles %s", trisRendered).to!dstring;
		trisRendered = 0;

		vec3 pos = fpsController.camera.position;
		lines[ 6]["text"] = format("Position: X %.2f, Y %.2f, Z %.2f",
			pos.x, pos.y, pos.z).to!dstring;

		vec3 target = fpsController.camera.target;
		lines[ 7]["text"] = format("Target: X %.2f, Y %.2f, Z %.2f",
			target.x, target.y, target.z).to!dstring;
	}

	void windowResized(uvec2 newSize)
	{
		fpsController.camera.aspect = cast(float)newSize.x/newSize.y;
		fpsController.camera.updatePerspective();
	}

	override void draw()
	{
		guiRenderer.setClientArea(Rect(0, 0, window.size.x, window.size.y));
		glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT);

		renderer.disableAlphaBlending();
		drawScene();
		renderer.enableAlphaBlending();

		context.eventDispatcher.draw();

		window.swapBuffers();
	}

	void drawScene()
	{
		glEnable(GL_DEPTH_TEST);
		
		chunkShader.bind;
		glUniformMatrix4fv(worldToCameraMatrixLoc, 1, GL_FALSE,
			fpsController.cameraMatrix);
		glUniformMatrix4fv(cameraToClipMatrixLoc, 1, GL_FALSE,
			cast(const float*)fpsController.camera.perspective.arrayof);

		Matrix4f modelToWorldMatrix;
		foreach(Chunk* c; chunkMan.visibleChunks)
		{
			// Frustum culling
			/*svec4 svecMin = c.coord.vector * chunkSize;
			vec3 vecMin = vec3(svecMin.x, svecMin.y, svecMin.z);
			vec3 vecMax = vecMin + chunkSize;
			auto result = fpsController.camera.frustumAABBIntersect(vecMin, vecMax);
			if (result == IntersectionResult.outside) continue;*/
			if (!c.hasMesh) continue;

			modelToWorldMatrix = translationMatrix!float(c.mesh.position);
			glUniformMatrix4fv(modelToWorldMatrixLoc, 1, GL_FALSE,
				cast(const float*)modelToWorldMatrix.arrayof);
			
			c.mesh.bind;
			c.mesh.render;
			++chunksRendered;
			vertsRendered += c.mesh.numVertexes;
			trisRendered += c.mesh.numTris;
		}
		chunkShader.unbind;

		glDisable(GL_DEPTH_TEST);
		
		renderer.setColor(Color(0,0,0,1));
		//renderer.drawRect(Rect(width/2-7, height/2-1, 14, 2));
		//renderer.drawRect(Rect(width/2-1, height/2-7, 2, 14));
	}

	void updateController(double dt)
	{
		if(mouseLocked)
		{
			ivec2 mousePos = window.mousePosition;
			mousePos -= cast(ivec2)(window.size) / 2;

			if(mousePos.x !=0 || mousePos.y !=0)
			{
				fpsController.rotateHor(mousePos.x);
				fpsController.rotateVert(mousePos.y);
			}
			window.mousePosition = cast(ivec2)(window.size) / 2;

			uint cameraSpeed = 30;
			vec3 posDelta = vec3(0,0,0);
			if(window.isKeyPressed(KeyCode.KEY_LEFT_SHIFT)) cameraSpeed = 80;

			if(window.isKeyPressed(KeyCode.KEY_D)) posDelta.x = 1;
			else if(window.isKeyPressed(KeyCode.KEY_A)) posDelta.x = -1;

			if(window.isKeyPressed(KeyCode.KEY_W)) posDelta.z = 1;
			else if(window.isKeyPressed(KeyCode.KEY_S)) posDelta.z = -1;

			if(window.isKeyPressed(GLFW_KEY_SPACE)) posDelta.y = 1;
			else if(window.isKeyPressed(GLFW_KEY_LEFT_CONTROL)) posDelta.y = -1;

			if (posDelta != vec3(0))
			{
				posDelta *= cameraSpeed * dt;
				fpsController.moveAxis(posDelta);
			}
		}
	}

	void keyReleased(uint keyCode)
	{
		switch(keyCode)
		{
			case KeyCode.KEY_Q: mouseLocked = !mouseLocked;
				if (mouseLocked)
					window.mousePosition = cast(ivec2)(window.size) / 2;
				break;
			case KeyCode.KEY_P: fpsController.printVectors; break;
			case KeyCode.KEY_I: fpsController.moveAxis(vec3(0, 0, 1)); break;
			case KeyCode.KEY_K: fpsController.moveAxis(vec3(0, 0, -1)); break;
			case KeyCode.KEY_J: fpsController.moveAxis(vec3(-1, 0, 0)); break;
			case KeyCode.KEY_L: fpsController.moveAxis(vec3(1, 0, 0)); break;
			case KeyCode.KEY_O: fpsController.moveAxis(vec3(0, 1, 0)); break;
			case KeyCode.KEY_U: fpsController.moveAxis(vec3(0, -1, 0)); break;
			case KeyCode.KEY_UP: fpsController.rotateVert(-45); break;
			case KeyCode.KEY_DOWN: fpsController.rotateVert(45); break;
			case KeyCode.KEY_LEFT: fpsController.rotateHor(-45); break;
			case KeyCode.KEY_RIGHT: fpsController.rotateHor(45); break;
			case KeyCode.KEY_R: resetCamera(); break;
			default: break;
		}
	}

	void resetCamera()
	{
		fpsController.camera.position=vec3(0,0,0);
		fpsController.angleHor = 0;
		fpsController.angleVert = 0;		
		fpsController.update();
	}

	override void closePressed()
	{
		isRunning = false;
	}
}

//------------------------------------------------------------------------------
//------------------------------- Chunk storage --------------------------------
//------------------------------------------------------------------------------

import std.algorithm : filter;
import std.conv : to;
import voxelman.chunkmesh;

enum chunkSize = 16;
alias BlockType = ubyte;
alias Vector!(short, 4) svec4;

// chunk position in chunk coordinate space
struct ChunkCoord
{
	union
	{
		struct
		{
			short x, y, z;
			short _;
		}
		svec4 vector;
		ulong asLong;
	}

	alias vector this;

	string toString()
	{
		return format("{%s %s %s}", x, y, z);
	}

	bool opEquals(ChunkCoord other)
	{
		return asLong == other.asLong;
	}
}

// 3d slice of chunks
struct ChunkRange
{
	ChunkCoord coord;
	ivec3 size;

	int volume()
	{
		return size.x * size.y * size.z;
	}

	bool contains(ChunkCoord otherCoord)
	{
		if (otherCoord.x < coord.x || otherCoord.x >= coord.x + size.x) return false;
		if (otherCoord.y < coord.y || otherCoord.y >= coord.y + size.y) return false;
		if (otherCoord.z < coord.z || otherCoord.z >= coord.z + size.z) return false;
		return true;
	}

	import std.algorithm : cartesianProduct, map, joiner, equal, canFind;
	import std.range : iota;
	import std.array : array;

	auto chunkCoords()
	{
		return cartesianProduct(
			iota(coord.x, cast(short)(coord.x+size.x)),
			iota(coord.y, cast(short)(coord.y+size.y)),
			iota(coord.z, cast(short)(coord.z+size.z)))
			.map!((a)=>ChunkCoord(a[0], a[1], a[2]));
	}

	auto chunksNotIn(ChunkRange other)
	{
		auto intersection = rangeIntersection(this, other);
		ChunkRange[] ranges;

		if (intersection.size == ivec3(0,0,0)) 
			ranges = [this];
		else
			ranges = octoSlice(intersection)[]
				.filter!((a) => a != intersection)
				.array;

		return ranges
			.map!((a) => a.chunkCoords)
			.joiner;
	}

	unittest
	{
		ChunkRange cr = {{0,0,0}, ivec3(2,2,2)};
		ChunkRange other1 = {{1,1,1}, ivec3(2,2,2)}; // opposite intersection {1,1,1}
		ChunkRange other2 = {{2,2,2}, ivec3(2,2,2)}; // no intersection
		ChunkRange other3 = {{0,0,1}, ivec3(2,2,2)}; // half intersection
		ChunkRange other4 = {{0,0,-1}, ivec3(2,2,2)}; // half intersection

		ChunkRange half1 = {{0,0,0}, ivec3(2,2,1)};
		ChunkRange half2 = {{0,0,1}, ivec3(2,2,1)};

		assert( !cr.chunksNotIn(other1).canFind(ChunkCoord(1,1,1)) );
		assert( equal(cr.chunksNotIn(other2), cr.chunkCoords) );
		assert( equal(cr.chunksNotIn(other3), half1.chunkCoords) );
		assert( equal(cr.chunksNotIn(other4), half2.chunkCoords) );
	}

	/// Slice range in 8 pieces as octree by corner piece.
	/// Return all 8 pieces.
	/// corner piece must be in the corner of this range.
	ChunkRange[8] octoSlice(ChunkRange corner)
	{
		// opposite corner coordinates.
		short cx, cy, cz;

		if (corner.coord.x == coord.x) // x0
			cx = cast(short)(corner.coord.x + corner.size.x);
		else // x1
			cx = corner.coord.x;

		if (corner.coord.y == coord.y) // y0
			cy = cast(short)(corner.coord.y + corner.size.y);
		else // y1
			cy = corner.coord.y;

		if (corner.coord.z == coord.z) // z0
			cz = cast(short)(corner.coord.z + corner.size.z);
		else // z1
			cz = corner.coord.z;


		// origin coordinates
		short ox = coord.x, oy = coord.y, oz = coord.z;
		// opposite corner size.
		int csizex = size.x-(cx-ox), csizey = size.y-(cy-oy), csizez = size.z-(cz-oz);
		// origin size
		int osizex = size.x-csizex, osizey = size.y-csizey, osizez = size.z-csizez;
		//writefln("cx %s cy %s cz %s", cx, cy, cz);
		//writefln("csizex %s csizey %s csizez %s", csizex, csizey, csizez);
		//writefln("ox %s oy %s oz %s", ox, oy, oz);
		//writefln("osizex %s osizey %s osizez %s", osizex, osizey, osizez);
		//writefln("sizex %s sizey %s sizez %s", size.x, size.y, size.z);
		//writefln("Corner %s", corner);


		alias CC = ChunkCoord;
		ChunkRange rx0y0z0 = {CC(ox,oy,oz), ivec3(osizex, osizey, osizez)};
		ChunkRange rx0y0z1 = {CC(ox,oy,cz), ivec3(osizex, osizey, csizez)};
		ChunkRange rx0y1z0 = {CC(ox,cy,oz), ivec3(osizex, csizey, osizez)};
		ChunkRange rx0y1z1 = {CC(ox,cy,cz), ivec3(osizex, csizey, csizez)};

		ChunkRange rx1y0z0 = {CC(cx,oy,oz), ivec3(csizex, osizey, osizez)};
		ChunkRange rx1y0z1 = {CC(cx,oy,cz), ivec3(csizex, osizey, csizez)};
		ChunkRange rx1y1z0 = {CC(cx,cy,oz), ivec3(csizex, csizey, osizez)};
		ChunkRange rx1y1z1 = {CC(cx,cy,cz), ivec3(csizex, csizey, csizez)};

		return [
		rx0y0z0, rx0y0z1, rx0y1z0, rx0y1z1,
		rx1y0z0, rx1y0z1, rx1y1z0, rx1y1z1];
	}
}

ChunkRange rangeIntersection(ChunkRange r1, ChunkRange r2)
{
	ChunkRange result;
	if (r1.coord.x < r2.coord.x)
	{
		if (r1.coord.x + r1.size.x < r2.coord.x) return ChunkRange();
		result.coord.x = r2.coord.x;
		result.size.x = r1.size.x - (r2.coord.x - r1.coord.x);
	}
	else
	{
		if (r2.coord.x + r2.size.x < r1.coord.x) return ChunkRange();
		result.coord.x = r1.coord.x;
		result.size.x = r2.size.x - (r1.coord.x - r2.coord.x);
	}

	if (r1.coord.y < r2.coord.y)
	{
		if (r1.coord.y + r1.size.y < r2.coord.y) return ChunkRange();
		result.coord.y = r2.coord.y;
		result.size.y = r1.size.y - (r2.coord.y - r1.coord.y);
	}
	else
	{
		if (r2.coord.y + r2.size.y < r1.coord.y) return ChunkRange();
		result.coord.y = r1.coord.y;
		result.size.y = r2.size.y - (r1.coord.y - r2.coord.y);
	}

	if (r1.coord.z < r2.coord.z)
	{
		if (r1.coord.z + r1.size.z < r2.coord.z) return ChunkRange();
		result.coord.z = r2.coord.z;
		result.size.z = r1.size.z - (r2.coord.z - r1.coord.z);
	}
	else
	{
		if (r2.coord.z + r2.size.z < r1.coord.z) return ChunkRange();
		result.coord.z = r1.coord.z;
		result.size.z = r2.size.z - (r1.coord.z - r2.coord.z);
	}

	result.size.x = result.size.x > 0 ? result.size.x : -result.size.x;
	result.size.y = result.size.y > 0 ? result.size.y : -result.size.y;
	result.size.z = result.size.z > 0 ? result.size.z : -result.size.z;

	return result;
}

unittest
{
	assert(rangeIntersection(
		ChunkRange(ChunkCoord(0,0,0), ivec3(2,2,2)),
		ChunkRange(ChunkCoord(1,1,1), ivec3(2,2,2))) ==
		ChunkRange(ChunkCoord(1,1,1), ivec3(1,1,1)));
	assert(rangeIntersection(
		ChunkRange(ChunkCoord(0,0,0), ivec3(2,2,2)),
		ChunkRange(ChunkCoord(3,3,3), ivec3(4,4,4))) ==
		ChunkRange(ChunkCoord()));
	assert(rangeIntersection(
		ChunkRange(ChunkCoord(1,1,1), ivec3(2,2,2)),
		ChunkRange(ChunkCoord(0,0,0), ivec3(2,2,2))) ==
		ChunkRange(ChunkCoord(1,1,1), ivec3(1,1,1)));
	assert(rangeIntersection(
		ChunkRange(ChunkCoord(1,1,1), ivec3(1,1,1)),
		ChunkRange(ChunkCoord(1,1,1), ivec3(1,1,1))) ==
		ChunkRange(ChunkCoord(1,1,1), ivec3(1,1,1)));
	assert(rangeIntersection(
		ChunkRange(ChunkCoord(0,0,0), ivec3(2,2,2)),
		ChunkRange(ChunkCoord(0,0,-1), ivec3(2,2,2))) ==
		ChunkRange(ChunkCoord(0,0,0), ivec3(2,2,1)));
}

struct ChunkSide
{
	/// null if homogeneous is true, or contains chunk slice otherwise
	BlockType[] typeData;
	/// type of common block
	BlockType uniformType = 0; // Unknown block
	/// is chunk filled with block of the same type
	bool uniform = true;

	Side side;
}

// Chunk data
struct ChunkData
{
	/// null if homogeneous is true, or contains chunk data otherwise
	BlockType[] typeData;
	/// type of common block
	BlockType uniformType = 0; // Unknown block
	/// is chunk filled with block of the same type
	bool uniform = true;

	ChunkSide getSide(Side side)
	{
		final switch(side)
		{
			case Side.north:
			case Side.south:
			case Side.east:
			case Side.west:
			case Side.bottom:
			case Side.top:
		}
	}
}

// Single chunk
struct Chunk
{
	enum State
	{
		notLoaded, // needs loading
		isLoading, // do nothing while loading
		isMeshing, // do nothing while meshing
		ready,     // render
		//changed,   // needs meshing, render
	}

	@disable this();

	this(ChunkCoord coord)
	{
		this.coord = coord;
		mesh = new ChunkMesh();
	}

	BlockType getBlockType(ubyte cx, ubyte cy, ubyte cz)
	{
		if (data.uniform) return data.uniformType;
		return data.typeData[cx + cy*chunkSize^^2 + cz*chunkSize];
	}

	ChunkData data;
	ChunkMesh mesh;
	ChunkCoord coord;
	Chunk*[6] neighbours;

	bool isLoaded = false;
	bool isVisible = false;
	bool hasMesh = false;
}

struct ChunkGenResult
{
	ChunkData chunkData;
	ChunkCoord coord;
}

struct MeshGenResult
{
	ubyte[] meshData;
	ChunkCoord coord;
}

//------------------------------------------------------------------------------
//------------------------------ Chunk storage ---------------------------------
//------------------------------------------------------------------------------

// 
struct ChunkMan
{
	ChunkRange visibleRegion;
	__gshared Chunk*[ulong] chunks;
	ChunkCoord observerPosition = ChunkCoord(short.max, short.max, short.max);
	uint viewRadius = 10;
	IBlock[] blockTypes;

	Chunk* unknownChunk;
	Chunk*[6] unknownNeighbours;

	void init()
	{
		loadBlockTypes();
		unknownChunk = new Chunk(ChunkCoord(0, 0, 0));
		unknownNeighbours = 
		[unknownChunk, unknownChunk, unknownChunk,
		 unknownChunk, unknownChunk, unknownChunk];
		static void doNothing(){}
		taskPool.put(task!doNothing());
		spawn(&doNothing);
	}

	void stop()
	{
		taskPool.stop;
	}

	void update()
	{
		bool message = true;
		while (message)
		{
			message = receiveTimeout(0.msecs,
				(immutable(ChunkGenResult)* data){onChunkLoaded(cast(ChunkGenResult*)data);},
				(immutable(MeshGenResult)* data){onMeshLoaded(cast(MeshGenResult*)data);}
				);
		}
	}

	void onChunkLoaded(ChunkGenResult* data)
	{
		if (!visibleRegion.contains(data.coord))
		{
			// TODO: destroy data
			return;
		}

		//writefln("Chunk data received in main thread");

		Chunk* chunk = getChunk(data.coord);

		chunk.isVisible = true;
		if (data.chunkData.uniform)
		{
			chunk.isVisible = blockTypes[data.chunkData.uniformType].isVisible;
		}
		
		chunk.data = data.chunkData;
		chunk.isLoaded = true;

		++totalLoadedChunks;

		if (chunk.isVisible)
		{
			auto pool = taskPool();
			pool.put(task!chunkMeshWorker(chunk, chunk.neighbours, &this, thisTid()));
			//chunkMeshWorker(chunk, cman);
		}
	}

	void onMeshLoaded(MeshGenResult* data)
	{
		if (!visibleRegion.contains(data.coord))
		{
			// TODO: destroy data
			return;
		}

		Chunk* chunk = getChunk(data.coord);

		chunk.mesh.data = data.meshData;
		
		ChunkCoord coord = chunk.coord;
		chunk.mesh.position = vec3(coord.x, coord.y, coord.z) * chunkSize;
		chunk.mesh.isDataDirty = true;
		chunk.hasMesh = chunk.mesh.data.length > 0;

		//writefln("Chunk mesh generated at %s", chunk.coord);
	}

	void loadBlockTypes()
	{
		blockTypes ~= new UnknownBlock(0);
		blockTypes ~= new AirBlock(1);
		blockTypes ~= new SolidBlock(2);
	}

	Chunk* createEmptyChunk(ChunkCoord coord)
	{
		return new Chunk(coord);
	}

	Chunk* getChunk(ChunkCoord coord)
	{
		Chunk** chunk = coord.asLong in chunks;
		if (chunk is null) return unknownChunk;
		return *chunk;
	}

	@property auto visibleChunks()
	{
		return chunks
		.byValue
		.filter!((c) => c.isLoaded && c.isVisible);
	}

	void updateObserverPosition(vec3 cameraPos)
	{
		ChunkCoord chunkPos = ChunkCoord(
			to!short(to!int(cameraPos.x) >> 4),
			to!short(to!int(cameraPos.y) >> 4),
			to!short(to!int(cameraPos.z) >> 4));

		if (chunkPos == observerPosition) return;

		auto size = viewRadius*2 + 1;
		ChunkRange newRegion = ChunkRange(
			cast(ChunkCoord)(chunkPos.vector - cast(short)viewRadius),
			ivec3(size, size, size));

		updateVisibleRegion(newRegion);
	}

	void updateVisibleRegion(ChunkRange newRegion)
	{
		auto oldRegion = visibleRegion;
		visibleRegion = newRegion;

		if (oldRegion.size == ivec3(0, 0, 0))
		{
			loadRegion(visibleRegion);
			return;
		}

		// remove chunks
		foreach(chunkCoord; oldRegion.chunksNotIn(newRegion))
		{
			removeChunk(getChunk(chunkCoord));
		}

		// load chunks
		foreach(chunkCoord; newRegion.chunksNotIn(oldRegion))
		{
			loadChunk(chunkCoord);
		}
	}

	// Add already created chunk to storage
	// Sets up all neighbours
	void addChunk(Chunk* chunk)
	{
		chunks[chunk.coord.asLong] = chunk;
		ChunkCoord coord = chunk.coord;

		void attachNeighbour(ubyte side)()
		{
			byte[3] offset = sideOffsets[side];
			ChunkCoord otherCoord = ChunkCoord(cast(short)(coord.x + offset[0]),
												cast(short)(coord.y + offset[1]),
												cast(short)(coord.z + offset[2]));
			Chunk* other = getChunk(otherCoord);

			other.neighbours[oppSide[side]] = chunk;
			chunk.neighbours[side] = other;
		}

		// Attach all neighbours
		attachNeighbour!(0)();
		attachNeighbour!(1)();
		attachNeighbour!(2)();
		attachNeighbour!(3)();
		attachNeighbour!(4)();
		attachNeighbour!(5)();
	}

	void removeChunk(Chunk* chunk)
	{
		if (chunk is unknownChunk) return;

		void detachNeighbour(ubyte side)()
		{
			if (chunk.neighbours[side])
			{
				chunk.neighbours[side].neighbours[oppSide[side]] = unknownChunk;
				chunk.neighbours[side] = null;
			}
		}

		// Detach all neighbours
		detachNeighbour!(0)();
		detachNeighbour!(1)();
		detachNeighbour!(2)();
		detachNeighbour!(3)();
		detachNeighbour!(4)();
		detachNeighbour!(5)();

		chunks.remove(chunk.coord.asLong);
	}

	void loadChunk(ChunkCoord coord)
	{
		if (coord.asLong in chunks) return;
		Chunk* chunk = createEmptyChunk(coord);
		addChunk(chunk);
		
		auto pool = taskPool();
		pool.put(task!chunkGenWorker(chunk.coord, thisTid()));
		++numLoadChunkTasks;
	}

	void loadRegion(ChunkRange region)
	{
		foreach(short x; region.coord.x..cast(short)(region.coord.x + region.size.x))
		foreach(short y; region.coord.y..cast(short)(region.coord.y + region.size.y))
		foreach(short z; region.coord.z..cast(short)(region.coord.z + region.size.z))
		{
			loadChunk(ChunkCoord(x, y, z));
		}
	}
}

// Stats
__gshared ulong numLoadChunkTasks;
__gshared ulong totalLoadedChunks;

//------------------------------------------------------------------------------
//----------------------------- Chunk generation -------------------------------
//------------------------------------------------------------------------------

// Gen single chunk
void chunkGenWorker(ChunkCoord coord, Tid mainThread)
{
	int wx = coord.x, wy = coord.y, wz = coord.z;

	ChunkData cd;
	cd.typeData = new BlockType[chunkSize^^3];
	cd.uniform = true;
	
	cd.typeData[0] = getBlock3d(
		wx*chunkSize,
		wy*chunkSize,
		wz*chunkSize);
	BlockType type = cd.typeData[0];
	
	int bx, by, bz;
	foreach(i; 1..chunkSize^^3)
	{
		bx = i & (chunkSize-1);
		by = (i>>8) & (chunkSize-1);
		bz = (i>>4) & (chunkSize-1);

		// Actual block gen
		cd.typeData[i] = getBlock3d(
			bx + wx * chunkSize,
			by + wy * chunkSize,
			bz + wz * chunkSize);

		if(cd.uniform && cd.typeData[i] != type)
		{
			cd.uniform = false;
		}
	}

	if(cd.uniform)
	{
		delete cd.typeData;
		cd.uniformType = type;
	}

	//writefln("Chunk generated at %s uniform %s", chunk.coord, chunk.data.uniform);

	auto result = cast(immutable(ChunkGenResult)*)new ChunkGenResult(cd, coord);
	mainThread.send(result);
}

import anchovy.utils.noise.simplex;

// Gen single block
BlockType getBlock2d( int x, int y, int z)
{
	enum numOctaves = 6;
	enum divider = 50; // bigger - smoother
	enum heightModifier = 4; // bigger - higher

	float noise = 0.0;
	foreach(i; 1..numOctaves+1)
	{
		// [-1; 1]
		noise += Simplex.noise(cast(float)x/(divider*i), cast(float)z/(divider*i))*i*heightModifier;
	}

	if (noise >= y) return 2;
	else return 1;
}

BlockType getBlock3d( int x, int y, int z)
{
	// [-1; 1]
	float noise = Simplex.noise(cast(float)x/42, cast(float)y/42, cast(float)z/42);
	if (noise > 0.5) return 2;
	else return 1;
}

//------------------------------------------------------------------------------
//------------------------------- Block data -----------------------------------
//------------------------------------------------------------------------------

// mesh for single block
immutable float[18][6] faces =
[
	[-0.5f,-0.5f,-0.5f, // triangle 1 : begin // north
	 0.5f,-0.5f,-0.5f,
	 0.5f, 0.5f,-0.5f, // triangle 1 : end
	-0.5f,-0.5f,-0.5f, // triangle 2 : begin
	 0.5f, 0.5f,-0.5f,
	-0.5f, 0.5f,-0.5f], // triangle 2 : end

	[0.5f,-0.5f, 0.5f, // south
	-0.5f,-0.5f, 0.5f,
	-0.5f, 0.5f, 0.5f,
	 0.5f,-0.5f, 0.5f,
	-0.5f, 0.5f, 0.5f,
	 0.5f, 0.5f, 0.5f],

	[0.5f,-0.5f,-0.5f, // east
	 0.5f,-0.5f, 0.5f,
	 0.5f, 0.5f, 0.5f,
	 0.5f,-0.5f,-0.5f,
	 0.5f, 0.5f, 0.5f,
	 0.5f, 0.5f,-0.5f],

	[-0.5f,-0.5f, 0.5f, // west
	-0.5f,-0.5f,-0.5f,
	-0.5f, 0.5f,-0.5f,
	-0.5f,-0.5f, 0.5f,
	-0.5f, 0.5f,-0.5f,
	-0.5f, 0.5f, 0.5f],

	[-0.5f,-0.5f, 0.5f, // bottom
	 0.5f,-0.5f, 0.5f,
	 0.5f,-0.5f,-0.5f,
	-0.5f,-0.5f, 0.5f,
	 0.5f,-0.5f,-0.5f,
	-0.5f,-0.5f,-0.5f],

	[0.5f, 0.5f, 0.5f, // top
	-0.5f, 0.5f, 0.5f,
	-0.5f, 0.5f,-0.5f,
	 0.5f, 0.5f, 0.5f,
	-0.5f, 0.5f,-0.5f,
	 0.5f, 0.5f,-0.5f]
];

immutable float[18] colors =
[0.0,0.7,0.0,
 0.0,0.75,0.0,
 0.0,0.6,0.0,
 0.0,0.5,0.0,
 0.0,0.4,0.0,
 0.0,0.85,0.0,];

enum Side : ubyte
{
	north	= 0,
	south	= 1,
	
	east	= 2,
	west	= 3,
	
	up		= 4,
	down	= 5,
}

immutable ubyte[6] oppSide =
[1, 0, 3, 2, 5, 4];

immutable byte[3][6] sideOffsets =
[
	[ 0, 0,-1],
	[ 0, 0, 1],
	[ 1, 0, 0],
	[-1, 0, 0],
	[ 0,-1, 0],
	[ 0, 1, 0],
];

abstract class IBlock
{
	this(BlockType id)
	{
		this.id = id;
	}
	// TODO remake as table
	//Must return true if the side allows light to pass
	bool isSideTransparent(ubyte side);

	bool isVisible();
	
	//Must return mesh for block in given position for given sides
	//sides is contains [6] bit flags of wich side must be builded
	float[] getMesh(ubyte bx, ubyte by, ubyte bz, ubyte sides, ubyte sidesnum);
	
	float texX1, texY1, texX2, texY2;
	BlockType id;
}

class SolidBlock : IBlock
{
	this(BlockType id){super(id);}

	override bool isSideTransparent(ubyte side) {return false;}

	override bool isVisible() {return true;}

	override float[] getMesh(ubyte bx, ubyte by, ubyte bz, ubyte sides, ubyte sidesnum)
	{
		float[] data;
		data.reserve(sidesnum*36);

		foreach(ubyte i; 0..6)
		{
			if (sides & (2^^i))
			{
				for (size_t v = 0; v!=18; v+=3)
				{
					data ~= faces[i][v]  +bx;
					data ~= faces[i][v+1]+by;
					data ~= faces[i][v+2]+bz;
					data ~= colors[i*3..i*3+3];
				} // for v
			} // if
		} // for i

		return data;
	}
}

class UnknownBlock : IBlock
{
	this(BlockType id){super(id);}

	override bool isSideTransparent(ubyte side) {return false;}

	override bool isVisible() {return false;}

	override float[] getMesh(ubyte bx, ubyte by, ubyte bz, ubyte sides, ubyte sidesnum)
	{
		return null;
	}
}

class AirBlock : IBlock
{
	this(BlockType id){super(id);}

	override bool isSideTransparent(ubyte side) {return true;}

	override bool isVisible() {return false;}

	override float[] getMesh(ubyte bx, ubyte by, ubyte bz, ubyte sides, ubyte sidesnum)
	{
		return null;
	}
}

//------------------------------------------------------------------------------
//-------------------- Chunk mesh generation -----------------------------------
//------------------------------------------------------------------------------
import core.exception;
void chunkMeshWorker(Chunk* chunk, Chunk*[6] neighbours, ChunkMan* cman, Tid mainThread)
{
	assert(chunk);
	assert(cman);

	Appender!(float[]) appender;
	ubyte bx, by, bz;

	//Chunk*[6] cNeigh = chunk.neighbours;
	//cNeigh[0] = *atomicLoadLocal(chunk.neighbours[0]);
	//cNeigh[1] = *atomicLoadLocal(chunk.neighbours[1]);
	//cNeigh[2] = *atomicLoadLocal(chunk.neighbours[2]);
	//cNeigh[3] = *atomicLoadLocal(chunk.neighbours[3]);
	//cNeigh[4] = *atomicLoadLocal(chunk.neighbours[4]);
	//cNeigh[5] = *atomicLoadLocal(chunk.neighbours[5]);

	IBlock[] blockTypes = cman.blockTypes;//*atomicLoadLocal(cman.blockTypes);

	bool isVisibleBlock(uint id)
	{
		return cman.blockTypes[id].isVisible;
	}
	
	bool getTransparency(int tx, int ty, int tz, ubyte side)
	{
		ubyte x = cast(ubyte)tx;
		ubyte y = cast(ubyte)ty;
		ubyte z = cast(ubyte)tz;

		if(tx == -1) // west
			return blockTypes[ neighbours[Side.west].getBlockType(chunkSize-1, y, z) ].isSideTransparent(side);
		else if(tx == 16) // east
			return blockTypes[ neighbours[Side.east].getBlockType(0, y, z) ].isSideTransparent(side);

		if(ty == -1) // bottom
			return blockTypes[ neighbours[Side.bottom].getBlockType(x, chunkSize-1, z) ].isSideTransparent(side);
		else if(ty == 16) // top
			return blockTypes[ neighbours[Side.top].getBlockType(x, 0, z) ].isSideTransparent(side);

		if(tz == -1) // north
			return blockTypes[ neighbours[Side.north].getBlockType(x, y, chunkSize-1) ].isSideTransparent(side);
		else if(tz == 16) // south
			return blockTypes[ neighbours[Side.south].getBlockType(x, y, 0) ].isSideTransparent(side);
		
		return blockTypes[ chunk.getBlockType(x, y, z) ].isSideTransparent(side);
	}
	

	ubyte sides = 0;
	ubyte sidenum = 0;
	byte[3] offset;

	if (chunk.data.uniform)
	{
		foreach (uint index; 0..chunkSize^^3)
		{
			bx = index & 15, by = (index>>8) & 15, bz = (index>>4) & 15;
			sides = 0;
			sidenum = 0;
			
			foreach(ubyte side; 0..6)
			{
				offset = sideOffsets[side];
				
				if(getTransparency(bx+offset[0], by+offset[1], bz+offset[2], side))
				{	
					sides |= 2^^(side);
					++sidenum;
				}
			}
			
			appender ~= cman.blockTypes[chunk.data.uniformType]
							.getMesh(bx, by, bz, sides, sidenum);
		} // foreach
	}
	else
	foreach (uint index, ref ubyte val; chunk.data.typeData)
	{
		if (isVisibleBlock(val))
		{	
			bx = index & 15, by = (index>>8) & 15, bz = (index>>4) & 15;
			sides = 0;
			sidenum = 0;
			
			foreach(ubyte side; 0..6)
			{
				offset = sideOffsets[side];
				
				if(getTransparency(bx+offset[0], by+offset[1], bz+offset[2], side))
				{	
					sides |= 2^^(side);
					++sidenum;
				}
			}
			
			appender ~= cman.blockTypes[val].getMesh(bx, by, bz, sides, sidenum);
		} // if(val != 0)
	} // foreach

	auto result = cast(immutable(MeshGenResult)*)new MeshGenResult(cast(ubyte[])appender.data, chunk.coord);
	mainThread.send(result);
}

void atomicStoreLocal(T)(ref T var, auto ref T value)
{
	atomicStore(*cast(shared(T)*)(&var), cast(shared(T))value);
}

T atomicLoadLocal(T)(ref const T var)
{
	return cast(T)atomicLoad(*cast(shared(const T)*)(&var));
}