// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
/*!
 * Handles keeping our list of workspaces synchronized
 * with the client.
 */
module vlsc.workspaces;

import io   = watt.io;
import json = watt.json;
import lsp  = vls.lsp;

/*!
 * If this is an LSP request relating to the list of workspaces,
 * handle it. If the message should go nowhere else, `false` is
 * returned.
 */
fn handleRequest(ro: lsp.RequestObject) bool
{
	switch (ro.methodName) {
	case "initialize":
		initialise(ro);
		return false;
	case "workspace/didChangeWorkspaceFolders":
		change(ro);
		return true;
	default:
		return false;
	}
}

/*!
 * Get the uris for all current workspaces (if any).
 */
fn getUris() string[]
{
	return gWorkspaces.values;
}

private:

struct Workspace
{
	name: string;
	uri:  string;
}

global gWorkspaces: string[string];  //!< Uri's indexed by uri. (For easy removal).

/*!
 * Given the initialize request sent from the client, handle
 * anything related to workspaces from it.
 */
fn initialise(ro: lsp.RequestObject)
{
	assert(ro.methodName == "initialize");
	workspaceFolders := lsp.getArrayKey(ro.params, "workspaceFolders");
	add(workspaceFolders);
}

/*!
 * Given a didChangeWorkspaceFolders request sent from the client,
 * add and/or remove workspaces as appropriate.
 */
fn change(ro: lsp.RequestObject)
{
	assert(ro.methodName == "workspace/didChangeWorkspaceFolders");
	event: json.Value;
	if (!lsp.validateKey(ro.params, "event", json.DomType.Object, ref event)) {
		return;
	}
	added   := lsp.getArrayKey(event, "added");
	add(added);
	removed := lsp.getArrayKey(event, "removed");
	remove(removed);
}

/*!
 * Given a json list of workspace objects ({name:string, uri:string}),
 * add every workspace to our list.
 */
fn add(workspaceList: json.Value[])
{
	array := getWorkspaceArray(workspaceList);
	foreach (ws; array) {
		add(ws);
	}
}

//! Add an individual workspace.
fn add(workspace: Workspace)
{
	gWorkspaces[workspace.uri] = workspace.uri;
}

/*!
 * Given a json list of workspace objects ({name:string, uri:string}),
 * remove every workspace from our list if present.
 */
fn remove(workspaceList: json.Value[])
{
	array := getWorkspaceArray(workspaceList);
	foreach (ws; array) {
		remove(ws);
	}
}

//! Remove an individual workspace.
fn remove(workspace: Workspace)
{
	if (p := workspace.uri in gWorkspaces) {
		gWorkspaces.remove(workspace.uri);
	}
}

/*!
 * Given a json list of workspace objects, create an array
 * of Workspace structs.
 */
fn getWorkspaceArray(list: json.Value[]) Workspace[]
{
	spaces := new Workspace[](list.length);
	for (i: size_t = 0; i < list.length; ++i) {
		spaces[i] = getWorkspace(list[i]);
	}
	return spaces;
}

/*!
 * Given a json workspace, return a Workspace struct.
 */
fn getWorkspace(val: json.Value) Workspace
{
	ws: Workspace;
	ws.name = lsp.getStringKey(val, "name");
	ws.uri  = lsp.getStringKey(val, "uri");
	return ws;
}
