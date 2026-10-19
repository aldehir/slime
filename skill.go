// Package slime is the root of the module: it carries what the slime
// CLI ships beside its code and the daemon's own protocol, so a build
// hands out what matches it.
package slime

import _ "embed"

// Skill is skills/slime/SKILL.md, the skill that teaches an agent to
// drive slime from a pane; `slime skill install` writes it out.
//
//go:embed skills/slime/SKILL.md
var Skill string
