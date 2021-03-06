/**
Copyright: Copyright (c) 2013-2017 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/

module anchovy.irenderer;

import voxelman.math;
import anchovy.texture;
import anchovy.shaderprogram;

interface IRenderer
{
	void alphaBlending(bool value);
	void depthWrite(bool value);
	void depthTest(bool value);
	void faceCulling(bool value);
	void faceCullMode(FaceCullMode mode);
	void wireFrameMode(bool value);
	void setViewport(ivec2 pos, ivec2 size);
	void setClearColor(ubyte r, ubyte g, ubyte b, ubyte a = 255);
	Texture createTexture(string filename);
	ShaderProgram createShaderProgram(string vertexSource, string fragmentSource);
	ivec2 framebufferSize() @property;
	void flush();
	void close();
}

import derelict.opengl3.gl3;
enum FaceCullMode
{
	front = GL_FRONT,
	back = GL_BACK,
	frontAndBack = GL_FRONT_AND_BACK
}
