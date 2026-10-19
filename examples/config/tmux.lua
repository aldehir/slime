-- tmux's key bindings as slime chords: ctrl+b, then a key.
--
-- Copy this beside init.lua and dofile("tmux.lua") from it, or make it
-- init.lua. Binding ctrl+b>... hides ctrl+b from the program; ctrl+b
-- ctrl+b sends it, as tmux's send-prefix does. Escape, or a key not in
-- the sequence, ends it. Only what slime has an action or a method for
-- is here: nothing needs a prompt (rename), a chooser (w, s), or copy
-- mode ([). Lua functions bound to a key run in the daemon for the
-- focused pane, so slime.tab and slime.workspace act on its tab and
-- workspace.

local prefix = "ctrl+b"

local function chord(key) return prefix .. ">" .. key end

-- Windows are tabs.
slime.bind(chord("c"), "new_tab")
slime.bind(chord("n"), "next_tab")
slime.bind(chord("p"), "previous_tab")
slime.bind(chord("shift+7"), function() assert(slime.tab.close{}) end) -- & kill-window

-- 0-9 select the window by number, from 0 as tmux's base-index does.
for n = 0, 9 do
  slime.bind(chord(tostring(n)), function()
    local ws = assert(slime.workspace.info{})
    local tab = ws.tabs[n + 1]
    if tab then assert(slime.workspace.focus{ tab = tab.id }) end
  end)
end

-- l goes to the last window: a hook remembers each workspace's previous
-- tab as the selection moves.
local last, current = {}, {}
slime.on("tab.selected", function(ctx, ev)
  local id = slime.id.parse(ev.id)
  if current[id.workspace] ~= ev.id then
    last[id.workspace] = current[id.workspace]
    current[id.workspace] = ev.id
  end
end)
slime.bind(chord("l"), function(ctx)
  local tab = last[ctx.workspace_id]
  if tab then assert(slime.workspace.focus{ tab = tab }) end
end)

-- Panes are splits. tmux's % is a pane to the right and " one below.
slime.bind(chord("shift+5"), "new_split", { direction = "right" })
slime.bind(chord("shift+apostrophe"), "new_split", { direction = "down" })
slime.bind(chord("x"), "close_surface")
slime.bind(chord("shift+1"), function() assert(slime.pane.move{}) end) -- ! break-pane into a tab of its own
slime.bind(chord("z"), "toggle_split_zoom")
slime.bind(chord("shift+e"), "equalize_splits")

slime.bind(chord("o"), "goto_split", { direction = "next" })
slime.bind(chord("semicolon"), "goto_split", { direction = "previous" })
for _, dir in ipairs({ "up", "down", "left", "right" }) do
  slime.bind(chord(dir), "goto_split", { direction = dir })
  slime.bind(chord("ctrl+" .. dir), "resize_split", { direction = dir, amount = 1 })
  slime.bind(chord("alt+" .. dir), "resize_split", { direction = dir, amount = 5 })
end

-- ] pastes; there is no paste buffer, so the clipboard is it.
slime.bind(chord("bracketright"), "paste_from_clipboard")

-- d detaches: the windows showing the workspace drop it and it runs on.
slime.bind(chord("d"), function() assert(slime.workspace.detach{}) end)

-- ctrl+b ctrl+b sends ctrl+b (0x02) to the program.
slime.bind(chord(prefix), function() assert(slime.pane.write{ text = "\2" }) end)
