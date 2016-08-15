/**
Copyright: Copyright (c) 2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.math;

public import gfm.integers.half;
public import dlib.math.vector;
public import std.math : isNaN, floor;
public import voxelman.math.utils;

alias hvec3 = Vector!(half, 3);
