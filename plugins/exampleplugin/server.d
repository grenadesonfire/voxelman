module exampleplugin.server;

import std.experimental.logger;
import plugin;
import pinfo = exampleplugin.plugininfo;

shared static this()
{
	import plugin.pluginregistry;
	pluginRegistry.regServerPlugin(new ExamplePluginServer);
}

class ExamplePluginServer : IPlugin
{
	override string id() @property { return pinfo.id; }
	override string semver() @property { return pinfo.semver; }
	override void registerResourceManagers(void delegate(IResourceManager) registerHandler)
	{
		infof("%s registerResourceManagers", id);
	}
	override void registerResources(IResourceManagerRegistry resmanRegistry)
	{
		infof("%s registerResources", id);
	}
	override void preInit()
	{
		infof("%s preInit", id);
	}
	override void init(IPluginManager pluginman)
	{
		infof("%s init", id);
	}
	override void postInit()
	{
		infof("%s postInit", id);
	}
}
