/**
Copyright: Copyright (c) 2015 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/

module plugin.iplugin;

import resource;
import plugin;

/// Basic plugin interface.
abstract class IPlugin
{
	// i.e. "Test Plugin"
	string name() @property;
	// valid semver version string. i.e. 0.1.0-rc.1
	string semver() @property;
	// register needed config options. They are loaded before preInit is called.
	void registerResources(IResourceManagerRegistry resmanRegistry) {}
	// load/create needed resources
	void preInit() {}
	// get references to other plugins
	void init(IPluginManager pluginman) {}
	// called after init. Do something with data retrieved at previous stage.
	void postInit() {}
}
