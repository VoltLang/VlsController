'use strict';
// The module 'vscode' contains the VS Code extensibility API
// Import the module and reference it with the alias vscode in your code below
import * as vscode from 'vscode';
import * as net from 'net';
import * as path from 'path';

import { workspace, commands, Disposable, ExtensionContext, ProviderResult, Command } from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient';

// this method is called when your extension is activated
// your extension is activated the very first time the command is executed
export function activate(context: ExtensionContext) {
    const executablExt = process.platform == 'win32' ? '.exe' : '';
	const executable = 'VlsController' + executablExt;
    const command = context.asAbsolutePath(executable);
    const serverOptions = { command };
    
    // Options to control the language client
    const clientOptions: LanguageClientOptions = {
        // Register the server for plain text documents
        documentSelector: [{scheme: 'file', language: 'volt'}],
        synchronize: {
            // Synchronize the setting section 'languageServerExample' to the server
            configurationSection: 'volt',
            // Notify the server about file changes to '.clientrc files contain in the workspace
            fileEvents: workspace.createFileSystemWatcher('**/*.volt')
        }
    }
	
    // Create the language client and start the client.
    const client = new LanguageClient('Volt Language Server', serverOptions, clientOptions);
    const disposable = client.start();

    const commandDisposable = commands.registerCommand("vls.buildActiveFile", () => {
        client.sendRequest("workspace/executeCommand", {command:"vls.buildProject", arguments:[{fsPath:vscode.window.activeTextEditor.document.fileName}]});
    });
	
	// Push the disposable to the context's subscriptions so that the 
	// client can be deactivated on extension deactivation
    context.subscriptions.push(disposable);
    context.subscriptions.push(commandDisposable);
}

// this method is called when your extension is deactivated
export function deactivate() {
}