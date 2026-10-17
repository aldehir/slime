// Installs the Go callbacks (callbacks.go) on a terminal. In C because
// a Go file with //export can only declare C, not define it.
#include <string.h>
#include <ghostty/vt.h>
#include "_cgo_export.h"

// The MIME types OSC 52 and 5522 text comes as (clipboard.isTextMime).
static bool is_text_mime(GhosttyString mime) {
	static const char* names[] = {"text/plain", "text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING"};
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		size_t n = strlen(names[i]);
		if (mime.len == n && memcmp(mime.ptr, names[i], n) == 0) return true;
	}
	return false;
}

// A program's clipboard write (OSC 52, 5522): its text, or a clear,
// goes to Go for the client. The reply has to be made here, through
// the write's function pointer, which Go can't call. The client applies
// its own policy (clipboard-write); the program is told it worked.
static void slime_clipboard_write(GhosttyTerminal t, void* userdata, const GhosttyClipboardWrite* w) {
	GhosttyClipboardWriteReply reply = {.size = sizeof(reply), .result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED};
	// Windows has one clipboard, so there's no selection or primary.
	if (w->location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD) {
		if (w->contents_len == 0) {
			goClipboardWrite(t, userdata, NULL, 0);
			reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
		}
		for (size_t i = 0; i < w->contents_len; i++) {
			if (!is_text_mime(w->contents[i].mime)) continue;
			goClipboardWrite(t, userdata, (uint8_t*)w->contents[i].data.ptr, w->contents[i].data.len);
			reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
			break;
		}
	}
	w->reply(w, &reply);
}

GhosttyResult slime_install_callbacks(GhosttyTerminal t, uintptr_t userdata) {
	struct {
		GhosttyTerminalOption opt;
		const void* value;
	} opts[] = {
		{GHOSTTY_TERMINAL_OPT_USERDATA, (const void*)userdata},
		{GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void*)(GhosttyTerminalWritePtyFn)goWritePty},
		{GHOSTTY_TERMINAL_OPT_BELL, (const void*)(GhosttyTerminalBellFn)goBell},
		{GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, (const void*)(GhosttyTerminalTitleChangedFn)goTitleChanged},
		{GHOSTTY_TERMINAL_OPT_PWD_CHANGED, (const void*)(GhosttyTerminalPwdChangedFn)goPwdChanged},
		{GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, (const void*)(GhosttyTerminalDeviceAttributesFn)goDeviceAttributes},
		{GHOSTTY_TERMINAL_OPT_SIZE, (const void*)(GhosttyTerminalSizeFn)goSize},
		{GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE, (const void*)(GhosttyTerminalUnknownSequenceFn)goUnknownSequence},
		{GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, (const void*)(GhosttyTerminalSemanticPromptFn)goSemanticPrompt},
		{GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, (const void*)(GhosttyTerminalProgramStatusFn)goProgramStatus},
		{GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, (const void*)(GhosttyTerminalClipboardWriteFn)slime_clipboard_write},
	};
	for (size_t i = 0; i < sizeof(opts) / sizeof(opts[0]); i++) {
		GhosttyResult r = ghostty_terminal_set(t, opts[i].opt, opts[i].value);
		if (r != GHOSTTY_SUCCESS) return r;
	}
	return GHOSTTY_SUCCESS;
}

void slime_install_log(void) {
	ghostty_sys_set(GHOSTTY_SYS_OPT_LOG, (const void*)(GhosttySysLogFn)goLog);
}
