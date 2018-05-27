// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
/*!
 * Handles emitting diagnostics to the client.
 *
 * This keeps track of the last kind of diagnostic we output, and makes
 * sure that typing errors don't overwrite build errors etc.
 */
module vlsc.diagnostics;

import lsp = vls.lsp;

/*!
 * If appropriate, emit a given language server diagnostic.
 *
 * This will output if the last error output for this uri
 * was a language server diagnostic, or if it's empty.
 *
 * @Param uri The uri for the file to associate the diagnostic with.
 * @Param error The JSON LSP error object.
 */
fn emitLanguageServerDiagnostic(uri: string, error: string)
{
	addDiagnostic(uri, DiagnosticSource.LanguageServer, error);
}

/*!
 * Emit a build server diagnostic.
 *
 * @Param uri The uri for the file to associate the diagnostic with.
 * @Param buildTag A tag that ties errors generated from a particular build together.
 * @Param error The JSON LSP error object.
 */
fn emitBuildServerDiagnostic(uri: string, buildTag: string, error: string)
{
	addDiagnostic(uri, DiagnosticSource.BuildServer, error, buildTag);
}

/*!
 * Remove any diagnostics associated with the given buildTag,
 * or with no buildTag.  
 *
 * Emits a no diagnostic message to the client.
 */
fn clearBuildTag(buildTag: string)
{
	foreach (uri, diagnostic; gLastEmittedDiagnostic) {
		if (diagnostic.buildTag == buildTag) {
			gLastEmittedDiagnostic.remove(uri);
			lsp.send(lsp.buildNoDiagnostic(uri));
		}
	}
}

private:

enum DiagnosticSource
{
	Empty,
	LanguageServer,
	BuildServer,
}

struct Diagnostic
{
	global fn create(source: DiagnosticSource, error: string, buildTag: string) Diagnostic
	{
		d: Diagnostic;
		d.source = source;
		d.error = error;
		d.buildTag = buildTag;
		return d;
	}

	source: DiagnosticSource;
	error: string;
	buildTag: string;
}

global gLastEmittedDiagnostic: Diagnostic[string];

// Emit a diagnostic, setting `gLastEmittedDiagnostic`.
fn emitDiagnostic(uri: string, source: DiagnosticSource, error: string, buildTag: string = null)
{
	assert(source != DiagnosticSource.Empty);
	lsp.send(error);
	gLastEmittedDiagnostic[uri] = Diagnostic.create(source, error, buildTag);
}

// If appropriate, emit a new diagnostic for the given `uri`.
fn addDiagnostic(uri: string, source: DiagnosticSource, error: string, buildTag: string = null)
{
	assert(source != DiagnosticSource.Empty);
	currentSource := getCurrentSource(uri);

	final switch (currentSource) with (DiagnosticSource) {
	case Empty, LanguageServer:
		emitDiagnostic(uri, source, error, buildTag);
		return;
	case BuildServer:
		break;
	}

	if (source == DiagnosticSource.BuildServer) {
		emitDiagnostic(uri, source, error);
	}
}

// Get the current source associated with the given `uri`.
fn getCurrentSource(uri: string) DiagnosticSource
{
	currentSource := DiagnosticSource.Empty;
	if (p := uri in gLastEmittedDiagnostic) {
		currentSource = p.source;
	}
	return currentSource;
}
