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

// 256-color palette — crimson / deep red family
pub const red        = '${esc}[38;5;196m'  // bright red
pub const crimson    = '${esc}[38;5;160m'  // deep crimson (#d70000)
pub const dark_red   = '${esc}[38;5;124m'  // dark red (#af0000)
pub const maroon     = '${esc}[38;5;88m'   // deep maroon
pub const white      = '${esc}[38;5;255m'  // near-white
pub const gray       = '${esc}[38;5;245m'  // medium gray
pub const dark_gray  = '${esc}[38;5;240m'  // dark gray
pub const green      = '${esc}[38;5;76m'   // success green
pub const yellow     = '${esc}[38;5;220m'  // warning yellow

// --- Semantic helpers ---

// pkg formats a package name-version string.
pub fn pkg(s string) string {
	return '${bold}${crimson}${s}${reset}'
}

// repo formats a repository name.
pub fn repo(s string) string {
	return '${bold}${dark_red}${s}${reset}'
}

// err formats an error message.
pub fn err(s string) string {
	return '${bold}${red}error:${reset} ${s}'
}

// warn formats a warning message.
pub fn warn(s string) string {
	return '${bold}${yellow}warning:${reset} ${s}'
}

// ok formats a success / completion message.
pub fn ok(s string) string {
	return '${green}${s}${reset}'
}

// heading formats a section heading (like ":: Installing packages...").
pub fn heading(s string) string {
	return '${bold}${crimson}::${reset} ${bold}${s}${reset}'
}

// dim formats secondary / less important text.
pub fn muted(s string) string {
	return '${gray}${s}${reset}'
}

// version formats a version string.
pub fn version_str(s string) string {
	return '${crimson}${s}${reset}'
}

// arrow returns a styled arrow indicator.
pub fn arrow() string {
	return '${crimson}→${reset}'
}

// bullet returns a styled bullet point.
pub fn bullet() string {
	return '${crimson}•${reset}'
}
