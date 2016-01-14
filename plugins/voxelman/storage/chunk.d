/**
Copyright: Copyright (c) 2013-2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.storage.chunk;

import std.experimental.logger;
import std.array : uninitializedArray;
import std.string : format;

import dlib.math.vector;

import voxelman.core.config;
import voxelman.block.utils;
import voxelman.core.chunkmesh;
import voxelman.storage.coordinates;
import voxelman.storage.region;
import voxelman.storage.utils;


/// Container for chunk updates
/// If blockChanges is null uses newBlockData
struct ChunkChange
{
	BlockChange[] blockChanges;
	BlockData newBlockData;
}

// container of single block change.
// position is chunk local [0; CHUNK_SIZE-1];
struct BlockChange
{
	// index of block in chunk data
	ushort index;

	BlockId blockId;
}

ushort[2] areaOfImpact(BlockChange[] changes)
{
	ushort start;
	ushort end;

	foreach(change; changes)
	{
		if (change.index < start)
			start = change.index;
		if (change.index > end)
			end = change.index;
	}

	return cast(ushort[2])[start, end+1];
}

enum StorageType
{
	uniform,
	rle,
	array,
}

struct ChunkDataSnapshot {
	//BlockId[] blocks;
	BlockData blockData;
	TimestampType timestamp;
	uint numUsers;
}

// stores all used snapshots of the chunk. Current is blocks
struct BlockDataSnapshot
{
	BlockData blockData;
	TimestampType timestamp;
	uint numUsers;
}

// Stores blocks of the chunk
struct BlockData
{
	void validate()
	{
		if (!uniform && blocks.length != CHUNK_SIZE_CUBE) {
			fatalf("Size of uniform chunk != CHUNK_SIZE_CUBE, == %s", blocks.length);
		}
	}

	/// null if uniform is true, or contains chunk data otherwise
	BlockId[] blocks;

	/// type of common block
	BlockId uniformType = 0; // Unknown block

	/// is chunk filled with block of the same type
	bool uniform = true;

	void convertToArray()
	{
		if (uniform)
		{
			blocks = uninitializedArray!(BlockId[])(CHUNK_SIZE_CUBE);
			blocks[] = uniformType;
			uniform = false;
		}
	}

	void copyToBuffer(BlockId[] outBuffer)
	{
		assert(outBuffer.length == CHUNK_SIZE_CUBE);
		if (uniform)
			outBuffer[] = uniformType;
		else
			outBuffer[] = blocks;
	}

	void convertToUniform(BlockId _uniformType)
	{
		uniform = true;
		uniformType = _uniformType;
		deleteBlocks();
	}

	void deleteBlocks()
	{
		blocks = null;
	}

	BlockId getBlockType(BlockChunkIndex index)
	{
		if (uniform) return uniformType;
		return blocks[index];
	}

	// returns true if data was changed
	bool setBlockType(BlockChunkIndex index, BlockId blockId)
	{
		if (uniform)
		{
			if (uniformType != blockId)
			{
				convertToArray();
				blocks[index] = blockId;
				return true;
			}
		}
		else
		{
			if (blocks[index] == blockId)
				return false;

			blocks[index] = blockId;
			return true;
		}

		return false;
	}

	// returns [first changed index, last changed index + 1]
	// if they match, then no changes occured
	// for use on client, when handling MultiblockChangePacket
	ushort[2] applyChanges(BlockChange[] changes)
	{
		ushort start;
		ushort end;

		foreach(change; changes)
		{
			if (setBlockType(BlockChunkIndex(change.index), change.blockId))
			{
				if (change.index < start)
					start = change.index;
				if (change.index > end)
					end = change.index;
			}
		}

		return cast(ushort[2])[start, end+1];
	}

	// Same as applyChanges, but does only
	// change application, no area of impact is calculated
	void applyChangesFast(BlockChange[] changes)
	{
		foreach(change; changes)
		{
			setBlockType(BlockChunkIndex(change.index), change.blockId);
		}
	}

	//
	void applyChangesChecked(BlockChange[] changes)
	{
		foreach(change; changes)
		{
			if (change.index <= CHUNK_SIZE_CUBE)
				setBlockType(BlockChunkIndex(change.index), change.blockId);
		}
	}
}

// Single chunk
struct Chunk
{
	@disable this();

	this(ChunkWorldPos position)
	{
		this.position = position;
	}

	BlockId getBlockType(int x, int y, int z)
	{
		return getBlockType(BlockChunkIndex(x, y, z));
	}

	BlockId getBlockType(BlockChunkIndex blockChunkIndex)
	{
		return snapshot.blockData.getBlockType(blockChunkIndex);
	}

	bool allAdjacentLoaded() @property
	{
		foreach(a; adjacent)
		{
			if (a is null || !a.isLoaded) return false;
		}

		return true;
	}

	bool canBeMeshed() @property
	{
		return isLoaded && allAdjacentLoaded;
	}

	bool needsMesh() @property
	{
		return isLoaded && isVisible && !hasMesh && !isMeshing;
	}

	bool isUsed() @property
	{
		return numReaders > 0 || hasWriter;
	}

	bool adjacentUsed() @property
	{
		foreach(a; adjacent)
			if (a !is null && a.isUsed) return true;
		return false;
	}

	bool adjacentHasUnappliedChanges() @property
	{
		foreach(a; adjacent)
			if (a !is null && a.hasUnappliedChanges) return true;
		return false;
	}

	bool isMarkedForDeletion() @property
	{
		return next || prev;
	}

	BlockDataSnapshot* getReadableSnapshot(TimestampType timestamp)
	{
		if (isLoaded)
			return &snapshot;
		else
			return null;
	}

	BlockDataSnapshot* getWriteableSnapshot(TimestampType timestamp)
	{
		if (isLoaded)
		{
			snapshot.timestamp = timestamp;
			return &snapshot;
		}
		else
			return null;
	}

	ChunkWorldPos position;
	BlockDataSnapshot snapshot;
	ChunkMesh mesh;
	Chunk*[6] adjacent;

	// updates
	ChunkChange change;
	ubyte[] newMeshData; // used for swapping

	bool isLoaded = false;
	bool isVisible = false;
	bool hasMesh = false;
	bool isMeshing = false;


	// If marked, then chunk is awaiting remesh.
	// Do not add chunk to mesh if already dirty
	bool isDirty = false;

	// Used when remeshing.
	// true if chunk is in changedChunks queue and has unapplied changes
	bool hasUnappliedChanges = false;

	// How many tasks are reading or writing this chunk
	bool hasWriter = false;
	ushort numReaders = 0;

	// In deletion queue.
	Chunk* next;
	Chunk* prev;
}