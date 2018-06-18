# VLS - Volt For Visual Studio Code

This extension adds various features to Visual Studio Code to make working with [Volt](https://www.volt-lang.org) code an electrifying experience.

Features included:
- Syntax Highlighting
- Completion Lists
- Snippets
- File Outline
- Signature Help
- Build Project

## Setup

Currently VLS is only available for 64 bit Windows systems. Linux 64, and macOS support is planned. 32 bit support is more likely on Linux, less likely on Windows. Nothing is ruled out, however.

Open Visual Studio Code. Press `Ctrl+Shift+X` or  `Cmd+Shift+X` to go the extension pane. Install the VLS extension from there.

It'll work from there, but if you want the best experience, open your settings and fill out the following:

`volt.pathToVolta`: A string containing the absolute path to the [Volta Compiler Source Code](https://github.com/VoltLang/Volta), for completion of runtime functions.

`volt.pathToWatt`: A string containing the absolute path to the [Watt Standard Library Source Code](https://github.com/VoltLang/Watt), for completion of library functions.

If you've got a library that VLS can't find, you can set package overrides too:

```json
additionalPackagePaths": {
		"my.library": "D:\\Path\\To\\My\\Library\\Src",
		"her.library": "D:\\Path\\To\\Her\\Library\\Src",
}
```

Now whenever VLS sees an import starting with one of those package names, it'll look in the given path.

## Operation

Mostly the same as stock Visual Studio Code. By default, VLS adds a couple of keyboard shortcuts:

`Alt+F6`: Build the project associated with the current workspace.

`Alt+F7`: Build all Volt projects in the current workspace.

The build command will download a copy of `battery`, and the tools that it needs into the extension folder under `.toolchain`. If the project hasn't been configured, it'll try to do it itself. If your project is a bit more complex, you can run `battery config` from the commandline yourself, and `VLS` will just run `build`. If you want to reconfigure the project, just delete the appropriate `.battery` directory.

## Known Issues

A lot. VLS uses the same parsing and semantic code that the Volta compiler uses. Much strides have been made in making it more resilient to infinite monkeys typing code at it, but issues do happen.

The full semantic phase has not been implemented into VLS. In particular, this means that expressions aren't typed. Automatic variables (e.g. `a := 2`) will attempt to be typed with a crude heuristic, but this can often fail, so the various semantic procedures (completion, go to definition, etc) are a work in progress. We appreciate your patience with the tooling's current crude state, and are constantly working on it to make it better (if for no other reason than we use it ourselves, so it makes our lives better too).

The building doesn't give progress of any kind until completion. If it's the first time you've done it, it has to download the tools, so please be patient. VLS doesn't know how to handle any error that was generated from a non-Volta source, so linker errors and the like will likely not show up in the 'Problems' section, and the 'build failed' toast will be your only way to know something went wrong. You'll still have to keep that command prompt handy yet!

## Complaints

As detailed above, VLS is a work in progress. If you wish to submit a detailed problem report, please do so on the [VlsController](https://github.com/VoltLang/VlsController) project. We appreciate you taking the time to help us make VLS better. Happy coding!