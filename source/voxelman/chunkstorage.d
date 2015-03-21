/**
Copyright: Copyright (c) 2015 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.chunkstorage;

import dlib.math.vector : vec3, ivec3;
import voxelman.block;
import voxelman.chunk;

struct ChunkRemoveQueue
{
	Chunk* first; // head of slist. Follow 'next' pointer in chunk
	size_t length;

	void add(Chunk* chunk)
	{
		assert(chunk);
		assert(chunk !is null);

		// already queued
		if (chunk.isMarkedForDeletion) return;

		chunk.isLoaded = false;
		chunk.next = first;
		if (first) first.prev = chunk;
		first = chunk;
		++length;
	}

	void remove(Chunk* chunk)
	{
		assert(chunk);
		assert(chunk !is null);

		if (chunk.prev)
			chunk.prev.next = chunk.next;
		else
			first = chunk.next;

		if (chunk.next)
			chunk.next.prev = chunk.prev;

		chunk.next = null;
		chunk.prev = null;
		--length;
	}

	void process(void delegate(Chunk* chunk) chunkRemoveCallback)
	{
		Chunk* chunk = first;

		while(chunk)
		{
			assert(chunk !is null);

			if (!chunk.isUsed)
			{
				auto toRemove = chunk;
				chunk = chunk.next;

				remove(toRemove);
				chunkRemoveCallback(toRemove);
			}
			else
			{
				auto c = chunk;
				chunk = chunk.next;
			}
		}
	}
}

///
struct ChunkStorage
{
	Chunk*[ivec3] chunks;
	ChunkRemoveQueue removeQueue;
	void delegate(Chunk* chunk) onChunkRemoved;
	void delegate(Chunk* chunk) onChunkAdded;


	Chunk* getChunk(ivec3 coord)
	{
		return chunks.get(coord, null);
	}

	void update()
	{
		removeQueue.process(&removeChunk);
	}

	Chunk* createEmptyChunk(ivec3 coord)
	{
		return new Chunk(coord);
	}

	bool loadChunk(ivec3 coord)
	{
		if (auto chunk = chunks.get(coord, null))
		{
			if (chunk.isMarkedForDeletion)
				removeQueue.remove(chunk);
			return chunk.isLoaded;
		}

		Chunk* chunk = createEmptyChunk(coord);
		addChunk(chunk);

		return false;
	}

	// Add already created chunk to storage
	// Sets up all adjacent
	private void addChunk(Chunk* emptyChunk)
	{
		assert(emptyChunk);
		chunks[emptyChunk.coord] = emptyChunk;
		ivec3 coord = emptyChunk.coord;

		void attachAdjacent(ubyte side)()
		{
			byte[3] offset = sideOffsets[side];
			ivec3 otherCoord = ivec3(cast(int)(coord.x + offset[0]),
												cast(int)(coord.y + offset[1]),
												cast(int)(coord.z + offset[2]));
			Chunk* other = getChunk(otherCoord);

			if (other !is null)
				other.adjacent[oppSide[side]] = emptyChunk;
			emptyChunk.adjacent[side] = other;
		}

		// Attach all adjacent
		attachAdjacent!(0)();
		attachAdjacent!(1)();
		attachAdjacent!(2)();
		attachAdjacent!(3)();
		attachAdjacent!(4)();
		attachAdjacent!(5)();

		if (onChunkAdded)
			onChunkAdded(emptyChunk);
	}

	void removeChunk(Chunk* chunk)
	{
		assert(chunk);
		assert(!chunk.isUsed);

		void detachAdjacent(ubyte side)()
		{
			if (chunk.adjacent[side] !is null)
			{
				chunk.adjacent[side].adjacent[oppSide[side]] = null;
			}
			chunk.adjacent[side] = null;
		}

		// Detach all adjacent
		detachAdjacent!(0)();
		detachAdjacent!(1)();
		detachAdjacent!(2)();
		detachAdjacent!(3)();
		detachAdjacent!(4)();
		detachAdjacent!(5)();

		chunks.remove(chunk.coord);
		if (onChunkRemoved)
			onChunkRemoved(chunk);

		if (chunk.mesh)
			chunk.mesh.free();
		delete chunk.mesh;
		delete chunk;
	}
}
