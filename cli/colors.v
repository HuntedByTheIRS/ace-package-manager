// ANSI color constants — deep crimson theme for ace.
//
// Usage:
//   println(colors.bold + colors.red + 'error: ' + colors.reset + msg)
//   println(colors.pkg('zsh 5.9'))
//
// All functions that combine styles return the string including reset.
module cli

// --- Raw ANSI codes (using \033 octal for ESC) ---

const esc = '\033'

pub const reset  = '${esc}[0m'
pub const bold   = '${esc}[1m'
pub const dim    = '${esc}[2m'

// 256-color palette — crimson / deep red family + complementary accents
pub const red        = '${esc}[38;5;196m'  // bright red
pub const crimson    = '${esc}[38;5;160m'  // deep crimson (#d70000)
pub const dark_red   = '${esc}[38;5;124m'  // dark red (#af0000)
pub const maroon     = '${esc}[38;5;88m'   // deep maroon
pub const orange     = '${esc}[38;5;208m'  // warm orange (#ff8700)
pub const dark_green = '${esc}[38;5;28m'   // deep forest green (#008700)
pub const soft_green = '${esc}[38;5;35m'   // soft green
pub const light_pink = '${esc}[38;5;211m'  // soft pink (#ff87af)
pub const white      = '${esc}[38;5;255m'  // near-white
pub const gray       = '${esc}[38;5;245m'  // medium gray
pub const dark_gray  = '${esc}[38;5;240m'  // dark gray
pub const green      = '${esc}[38;5;76m'   // success green
pub const yellow     = '${esc}[38;5;220m'  // warning yellow

// --- Raw ANSI codes for bright backgrounds (used sparingly) ---

pub const bg_crimson = '${esc}[48;5;160m'

// --- Semantic helpers ---
//
// All helpers honor the global color mode (see use_color): with
// --color never / NO_COLOR they return the plain string.

// pkg formats a package name string (bold crimson — primary branding).
pub fn pkg(s string) string {
	if !use_color() {
		return s
	}
	return '${bold}${crimson}${s}${reset}'
}

// pkg_version formats a version string (crimson, no bold).
pub fn pkg_version(s string) string {
	if !use_color() {
		return s
	}
	return '${crimson}${s}${reset}'
}

// installed formats an already-installed indicator (dark green).
pub fn installed(s string) string {
	if !use_color() {
		return s
	}
	return '${dark_green}${s}${reset}'
}

// new_pkg formats a new package indicator (light pink).
pub fn new_pkg(s string) string {
	if !use_color() {
		return s
	}
	return '${light_pink}${s}${reset}'
}

// repo formats a repository name.
pub fn repo(s string) string {
	if !use_color() {
		return s
	}
	return '${bold}${dark_red}${s}${reset}'
}

// err formats an error message.
pub fn err(s string) string {
	if !use_color() {
		return 'error: ${s}'
	}
	return '${bold}${red}error:${reset} ${s}'
}

// warn formats a warning message.
pub fn warn(s string) string {
	if !use_color() {
		return 'warning: ${s}'
	}
	return '${bold}${yellow}warning:${reset} ${s}'
}

// ok formats a success / completion message.
pub fn ok(s string) string {
	if !use_color() {
		return s
	}
	return '${green}${s}${reset}'
}

// heading formats a section heading (like ":: Installing packages...").
pub fn heading(s string) string {
	if !use_color() {
		return ':: ${s}'
	}
	return '${bold}${crimson}::${reset} ${bold}${s}${reset}'
}

// dim formats secondary / less important text.
pub fn muted(s string) string {
	if !use_color() {
		return s
	}
	return '${gray}${s}${reset}'
}

// version_str formats a version string.
pub fn version_str(s string) string {
	if !use_color() {
		return s
	}
	return '${crimson}${s}${reset}'
}

// arrow returns a styled arrow indicator.
pub fn arrow() string {
	if !use_color() {
		return '->'
	}
	return '${crimson}→${reset}'
}

// bullet returns a styled bullet point.
pub fn bullet() string {
	if !use_color() {
		return '•'
	}
	return '${crimson}•${reset}'
}

// progress formats download/install progress (orange).
pub fn progress(s string) string {
	if !use_color() {
		return s
	}
	return '${orange}${s}${reset}'
}

// counter formats a numeric counter (bold orange — "Downloaded 3/10").
pub fn counter(s string) string {
	if !use_color() {
		return s
	}
	return '${bold}${orange}${s}${reset}'
}

// upgrade formats an upgrade indicator ("1.0 -> 2.0").
pub fn upgrade(from string, to string) string {
	if !use_color() {
		return '${from} -> ${to}'
	}
	return '${crimson}${from}${reset} ${arrow()} ${light_pink}${to}${reset}'
}

// opt_dep formats an optional dependency entry.
pub fn opt_dep(name string, desc string) string {
	if !use_color() {
		return if desc != '' { '${name}: ${desc}' } else { name }
	}
	if desc != '' {
		return '${light_pink}${name}${reset}${gray}: ${desc}${reset}'
	}
	return '${light_pink}${name}${reset}'
}

// err_str is a non-shadowed alias for err(), for use inside `or {}`
// blocks where the identifier `err` binds to the error value.
fn err_str(s string) string {
	return err(s)
}

