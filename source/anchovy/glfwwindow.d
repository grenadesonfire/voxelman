/**
Copyright: Copyright (c) 2013-2017 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/

module anchovy.glfwwindow;

import std.conv : to;
import std.string : toStringz, fromStringz, format;

import derelict.glfw3.glfw3;
import derelict.opengl3.gl3;
import voxelman.log;
import voxelman.math;
import anchovy.iwindow : IWindow;
import anchovy.isharedcontext;

class GlfwSharedContext : ISharedContext
{
	GLFWwindow* sharedContext;

	this(GLFWwindow* _sharedContext)
	{
		this.sharedContext = _sharedContext;
	}

	void makeCurrent()
	{
		glfwMakeContextCurrent(sharedContext);
	}
}

class GlfwWindow : IWindow
{
private:
	GLFWwindow*	glfwWindowPtr;
	static bool	glfwInited = false;
	bool isProcessingEvents = false;

public:
	override void init(ivec2 size, in string caption, bool center = false)
	{
		if (!glfwInited)
			initGlfw();

		scope(failure) glfwTerminate();

		glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
		glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 1);
		//glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
		glfwWindowHint(GLFW_VISIBLE, false);

		//BUG: sometimes fails in Windows 8. Maybe because of old drivers.
		glfwWindowPtr = glfwCreateWindow(size.x, size.y, toStringz(caption), null,  null);

		if (glfwWindowPtr is null)
		{
			throw new Error("Error creating GLFW3 window");
		}

		if (center) moveToCenter();

		glfwShowWindow(glfwWindowPtr);

		glfwMakeContextCurrent(glfwWindowPtr);
		glfwSwapInterval(0);

		glClearColor(1.0, 1.0, 1.0, 1.0);
		glViewport(0, 0, size.x, size.y);

		DerelictGL3.reload();

		glfwSetWindowUserPointer(glfwWindowPtr, cast(void*)this);
		glfwSetWindowPosCallback(glfwWindowPtr, &windowposfun);
		glfwSetFramebufferSizeCallback(glfwWindowPtr, &windowsizefun);
		glfwSetWindowCloseCallback(glfwWindowPtr, &windowclosefun);
		//glfwSetWindowRefreshCallback(glfwWindowPtr, &windowrefreshfun);
		glfwSetWindowFocusCallback(glfwWindowPtr, &windowfocusfun);
		glfwSetWindowIconifyCallback(glfwWindowPtr, &windowiconifyfun);
		glfwSetMouseButtonCallback(glfwWindowPtr, &mousebuttonfun);
		glfwSetCursorPosCallback(glfwWindowPtr, &cursorposfun);
		glfwSetScrollCallback(glfwWindowPtr, &scrollfun);
		glfwSetKeyCallback(glfwWindowPtr, &keyfun);
		glfwSetCharCallback(glfwWindowPtr, &charfun);
		//glfwSetCursorEnterCallback(window, GLFWcursorenterfun cbfun);
		glfwSetWindowRefreshCallback(glfwWindowPtr, &refreshfun);
	}

	override ISharedContext createSharedContext()
	{
		assert(glfwInited);
		assert(glfwWindowPtr);
		glfwWindowHint(GLFW_VISIBLE, false);
		GLFWwindow* sharedContext = glfwCreateWindow(100, 100, "", null, glfwWindowPtr);
		return new GlfwSharedContext(sharedContext);
	}

	override void moveToCenter()
	{
		GLFWmonitor* primaryMonitor = glfwGetPrimaryMonitor();
		ivec2 currentSize = size();
		ivec2 primPos;
		glfwGetMonitorPos(primaryMonitor, &primPos.x, &primPos.y);
		const GLFWvidmode* primMode = glfwGetVideoMode(primaryMonitor);
		ivec2 primSize = ivec2(primMode.width, primMode.height);
		ivec2 newPos = primPos + primSize/2 - currentSize/2;
		glfwSetWindowPos(glfwWindowPtr, newPos.x, newPos.y);
	}

	override void processEvents()
	{
		// prevent calling glfwPollEvents when inside window_refresh callback
		if (!isProcessingEvents)
		{
			isProcessingEvents = true;
			glfwPollEvents();
			isProcessingEvents = false;
		}
	}

	override double elapsedTime() @property //in seconds
	{
		return glfwGetTime();
	}

	override void reshape(ivec2 viewportSize)
	{
		glViewport(0, 0, viewportSize.x, viewportSize.y);
	}

	override void releaseWindow()
	{
		glfwDestroyWindow(glfwWindowPtr);
		glfwTerminate();
	}

	override void mousePosition(ivec2 newPosition) @property
	{
		glfwSetCursorPos(glfwWindowPtr, newPosition.x, newPosition.y);
	}

	override ivec2 mousePosition() @property
	{
		double x, y;
		glfwGetCursorPos(glfwWindowPtr, &x, &y);
		return ivec2(x, y);
	}

	override void swapBuffers()
	{
		glfwSwapBuffers(glfwWindowPtr);
	}

	override void size(ivec2 newSize) @property
	{
		glfwSetWindowSize(glfwWindowPtr, newSize.x, newSize.y);
	}

	override ivec2 size() @property
	{
		int width, height;
		glfwGetWindowSize(glfwWindowPtr, &width, &height);
		return ivec2(width, height);
	}

	override ivec2 framebufferSize() @property
	{
		int width, height;
		glfwGetFramebufferSize(glfwWindowPtr, &width, &height);
		return ivec2(width, height);
	}

	override string clipboardString() @property
	{
		const(char*) data = glfwGetClipboardString(glfwWindowPtr);
		if (data is null) return "";
		return cast(string)fromStringz(data);
	}

	override void clipboardString(string newClipboardString) @property
	{
		glfwSetClipboardString(glfwWindowPtr, toStringz(newClipboardString));
	}

	override bool isKeyPressed(uint key)
	{
		return glfwGetKey(glfwWindowPtr, key) == GLFW_PRESS;
	}

	override void setMouseLock(bool isMouseLocked)
	{
		if (isMouseLocked)
			glfwSetInputMode(glfwWindowPtr, GLFW_CURSOR, GLFW_CURSOR_DISABLED);
		else
			glfwSetInputMode(glfwWindowPtr, GLFW_CURSOR, GLFW_CURSOR_NORMAL);
	}

	GLFWwindow* handle() @property
	{
		return glfwWindowPtr;
	}

private:
	static void initGlfw()
	{
		glfwSetErrorCallback(&errorfun);

		if (glfwInit() == 0)
		{
			throw new Error("Error initializing GLFW3"); //TODO: add proper error handling
		}
		glfwInited = true;
	}
}

GlfwWindow getWinFromUP(GLFWwindow* w) nothrow
{
	GlfwWindow win;
	win = cast(GlfwWindow) glfwGetWindowUserPointer(w);
	return win;
}

extern(C) nothrow
{
	void errorfun(int errorCode, const(char)* msg)
	{
		throw new Error(format("GLFW error [%s] : %s", errorCode, fromStringz(msg)));
	}
	void windowposfun(GLFWwindow* w, int nx, int ny)
	{
		try getWinFromUP(w).windowMoved.emit(ivec2(nx, ny));
		catch(Exception e) throw new Error(to!string(e));
	}
	void windowsizefun(GLFWwindow* w, int newWidth, int newHeight)
	{
		try getWinFromUP(w).windowResized.emit(ivec2(newWidth, newHeight));
		catch(Exception e) throw new Error(to!string(e));
	}
	void windowclosefun(GLFWwindow* w)
	{
		try getWinFromUP(w).closePressed.emit();
		catch(Exception e) throw new Error(to!string(e));
	}
	void windowrefreshfun(GLFWwindow* w)
	{

	}
	void windowfocusfun(GLFWwindow* w, int focus)
	{
		try getWinFromUP(w).focusChanged.emit(cast(bool)focus);
		catch(Exception e) throw new Error(to!string(e));
	}
	void windowiconifyfun(GLFWwindow* w, int iconified)
	{
		try getWinFromUP(w).windowIconified.emit(cast(bool)iconified);
		catch(Exception e) throw new Error(to!string(e));
	}
	void mousebuttonfun(GLFWwindow* w, int mouseButton, int action, int)
	{
		try
		{
			if(action == GLFW_RELEASE)
			{
				getWinFromUP(w).mouseReleased.emit(mouseButton);
			}
			else
			{
				getWinFromUP(w).mousePressed.emit(mouseButton);
			}
		}
		catch(Exception e) throw new Error(to!string(e));
	}
	void cursorposfun(GLFWwindow* w, double nx, double ny)
	{
		try getWinFromUP(w).mouseMoved.emit(ivec2(cast(int)nx, cast(int)ny));
		catch(Exception e) throw new Error(to!string(e));
	}
	void scrollfun(GLFWwindow* w, double x, double y)
	{
		try getWinFromUP(w).wheelScrolled.emit(dvec2(x, y));
		catch(Exception e) throw new Error(to!string(e));
	}
	void cursorenterfun(GLFWwindow* w, int)
	{

	}
	void keyfun(GLFWwindow* w, int key, int, int action, int)
	{
		if (key < 0) return;
		try
		{
			if (action == GLFW_RELEASE)
			{
				getWinFromUP(w).keyReleased.emit(key);
			}
			else
			{
				getWinFromUP(w).keyPressed.emit(key);
			}
		}
		catch(Exception e) throw new Error(to!string(e));
	}
	void charfun(GLFWwindow* w, uint unicode)
	{
	    if (unicode > 0 && unicode < 0x10000) {
			try getWinFromUP(w).charEntered.emit(cast(dchar)unicode);
			catch(Exception e) throw new Error(to!string(e));
		}
	}
	void refreshfun(GLFWwindow* w)
	{
		try getWinFromUP(w).refresh.emit();
		catch(Exception e) throw new Error(to!string(e));
	}
}
