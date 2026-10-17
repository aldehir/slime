// Installs the Go callbacks (callbacks.go) on a terminal. In C because
// a Go file with //export can only declare C, not define it.
#include <ghostty/vt.h>
#include "_cgo_export.h"

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
