module modular.imodule;

import modular;

/// Basic module interface.
interface IModule
{
	// i.e. "Test Module"
	string name() @property;
	// valid semver version string. i.e. 0.1.0-rc.1
	string semver() @property;
	// load/create needed resources
	void load();
	// get references to other modules
	void init(IModuleManager moduleman);
}