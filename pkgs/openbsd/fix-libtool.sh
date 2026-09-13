# Libtool checks this base-system path to enable OpenBSD shared libraries.
fixOpenBSDLibtool() {
    if [[ -n "${dontFixLibtool:-}" || ! -f "${NIX_CC:-}/nix-support/dynamic-linker" ]]; then
        return
    fi

    local dynamicLinker
    dynamicLinker=$(cat "$NIX_CC/nix-support/dynamic-linker")
    find . -type f -executable -name configure -print0 | while IFS= read -r -d '' script; do
        if grep -qF /usr/libexec/ld.so "$script"; then
            local reference
            reference=$(mktemp)
            # Preserve mtimes, as in stdenv's other Libtool substitutions.
            touch -r "$script" "$reference"
            substituteInPlace "$script" \
                --replace-fail /usr/libexec/ld.so "$dynamicLinker"
            # Nixpkgs' LLD needs libfoo.so for -lfoo, not just libfoo.so.M.N.
            substituteInPlace "$script" \
                --replace-quiet \
                "library_names_spec='\$libname\$release\$shared_ext\$versuffix \$libname\$shared_ext\$versuffix'" \
                "library_names_spec='\$libname\$release\$shared_ext\$versuffix \$libname\$shared_ext\$versuffix \$libname\$shared_ext'"
            touch -r "$reference" "$script"
            rm "$reference"
        fi
    done
}

preConfigureHooks+=(fixOpenBSDLibtool)
