module util

// PkgNameSplit holds the four components of an Arch package specifier.
// Examples of parsed inputs:
//   "glibc-2.35-1-x86_64"   → name="glibc", version="2.35", release="1", arch="x86_64"
//   "gtk-update-icon-cache-3.24-1-x86_64" → name="gtk-update-icon-cache", version="3.24", ...
//   "glibc-2:2.35-1-x86_64" → name="glibc", version="2:2.35", ...  (epoch included in version)
pub struct PkgNameSplit {
pub:
	name    string
	version string
	release string
	arch    string
}

// PkgNameSplitWithExt is like PkgNameSplit but also retains the file extension
// stripped from a package filename.
pub struct PkgNameSplitWithExt {
	PkgNameSplit
pub:
	extension string
}

// known_pkg_extensions lists the recognised Arch package filename suffixes
// in order of preference (longest-first so greedy matching works).
const known_pkg_extensions = ['.pkg.tar.zst', '.pkg.tar.xz', '.pkg.tar.gz']

// ---------------------------------------------------------------------------
// split_pkgname
// ---------------------------------------------------------------------------

// split_pkgname splits a full package specifier into name, version, release,
// and arch.  The expected input format is:
//
//	[epoch:]version-release-arch
//
// where the name itself may contain hyphens, so parsing proceeds from the
// right.  Returns none for unparseable inputs.
//
// Supported variants:
//   name-version-release-arch   (4 fields — the standard form)
//   name-version-release        (no arch)
//   name-version-arch           (no release)
//   name-version                (no release, no arch)
//   epoch:version               (epoch is kept inside the version field)
pub fn split_pkgname(spec string) ?PkgNameSplit {
	if spec.len == 0 {
		return none
	}

	// Find up to three hyphens scanning from the right.
	mut hyphen_pos := []int{}
	for i := spec.len - 1; i >= 0; i-- {
		if spec[i] == `-` {
			hyphen_pos << i
			if hyphen_pos.len == 3 {
				break
			}
		}
	}

	// Need at least one hyphen (name-version minimum).
	if hyphen_pos.len == 0 {
		return none
	}

	// -- 3 hyphens: name-version-release-arch -------------------------------
	if hyphen_pos.len == 3 {
		h1, h2, h3 := hyphen_pos[0], hyphen_pos[1], hyphen_pos[2]
		pkgname := spec[..h3]
		version := spec[h3 + 1..h2]
		release := spec[h2 + 1..h1]
		arch := spec[h1 + 1..]

		if pkgname.len == 0 || version.len == 0 {
			return none
		}
		return PkgNameSplit{
			name:    pkgname
			version: version
			release: release
			arch:    arch
		}
	}

	// -- 2 hyphens: ambiguous — name-version-release OR name-version-arch ---
	if hyphen_pos.len == 2 {
		h1, h2 := hyphen_pos[0], hyphen_pos[1]
		pkgname := spec[..h2]
		mid := spec[h2 + 1..h1]
		last := spec[h1 + 1..]

		if pkgname.len == 0 || mid.len == 0 || last.len == 0 {
			return none
		}

		if segment_is_numeric(last) {
			// name-version-release  (last = numeric release)
			return PkgNameSplit{
				name:    pkgname
				version: mid
				release: last
				arch:    ''
			}
		} else {
			// name-version-arch  (last = non-numeric arch string)
			return PkgNameSplit{
				name:    pkgname
				version: mid
				release: ''
				arch:    last
			}
		}
	}

	// -- 1 hyphen: name-version --------------------------------------------
	h := hyphen_pos[0]
	pkgname := spec[..h]
	version := spec[h + 1..]
	if pkgname.len == 0 || version.len == 0 {
		return none
	}
	return PkgNameSplit{
		name:    pkgname
		version: version
		release: ''
		arch:    ''
	}
}

// ---------------------------------------------------------------------------
// split_pkgfile
// ---------------------------------------------------------------------------

// split_pkgfile splits an Arch package filename (e.g.
// "glibc-2.35-1-x86_64.pkg.tar.zst") into its named components plus the
// recognised extension.  Returns none when the filename does not end in a
// recognised Arch package extension or cannot be parsed.
pub fn split_pkgfile(filename string) ?PkgNameSplitWithExt {
	for ext in known_pkg_extensions {
		if filename.ends_with(ext) {
			base := filename[..filename.len - ext.len]
			split := split_pkgname(base)?
			return PkgNameSplitWithExt{
				name:      split.name
				version:   split.version
				release:   split.release
				arch:      split.arch
				extension: ext
			}
		}
	}
	return none
}

// ---------------------------------------------------------------------------
// internal helpers
// ---------------------------------------------------------------------------

// segment_is_numeric returns true when s is non-empty and every character is
// an ASCII digit.  Used to distinguish a release number from an arch string.
fn segment_is_numeric(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}
