# Screeps Typescript Starter

Screeps Typescript Starter is a starting point for a Screeps AI written in Typescript. It provides everything you need to start writing your AI whilst leaving `main.ts` as empty as possible.

## Basic Usage

You will need:

- [Node.JS](https://nodejs.org/en/download) (v24.x.x)
- [npm](https://docs.npmjs.com/getting-started/installing-node) (comes with Node.JS) or [bun](https://bun.sh/)

Download the latest source [here](https://github.com/screepers/screeps-typescript-starter/archive/master.zip) and extract it to a folder.

Open the folder in your terminal and run your package manager to install the required packages and TypeScript declaration files:

```bash
npm install
```

Fire up your preferred editor with typescript installed and you are good to go!

### Rolldown and code upload

Screeps Typescript Starter uses rolldown to compile your typescript and upload it to a screeps server.

Copy `screeps.example.yaml` to `screeps.yaml` and edit it, changing the credentials and optionally adding or removing some of the destinations.

_Note: you can also use a global file, which is located at `~/.config/screeps/config.yaml` on Linux and macOS, and `%APPDATA%\screeps\config.yaml` on Windows._

Running `rolldown -c` will compile your code and do a "dry run", preparing the code for upload but not actually pushing it. Running `rolldown -c --environment DEST:main` will compile your code, and then upload it to a screeps server using the `main` config from `screeps.yaml`. Leaving `DEST:` empty will prompt you to select a destination from the list of servers in your config file.

You can use `-cw` instead of `-c` to automatically re-run when your source code changes - for example, `rolldown -cw --environment DEST:main` will automatically upload your code to the `main` configuration every time your code is changed.

Finally, there are also NPM scripts that serve as aliases for these commands in `package.json` for IDE integration. Running `npm run push` is equivalent to `rolldown -c --environment DEST:`, and `npm run watch` is equivalent to `rolldown -cw`.

#### Important! To upload code to a private server, you must have [screepsmod-auth](https://github.com/ScreepsMods/screepsmod-auth) installed and configured!

## Typings

The type definitions for Screeps come from [typed-screeps](https://github.com/screepers/typed-screeps). If you find a problem or have a suggestion, please open an issue there.

## Documentation

To visit the docs, [click here](https://screepers.gitbook.io/screeps-typescript-starter/).

It includes all the essentials to get you up and running with Screeps AI development in TypeScript, as well as various other tips and tricks to further improve your development workflow.

Maintaining the docs will also become a more community-focused effort, which means you too, can take part in improving the docs for this starter kit.

## Contributing

Issues, Pull Requests, and contribution to the docs are welcome! See our [Contributing Guidelines](CONTRIBUTING.md) for more details.
