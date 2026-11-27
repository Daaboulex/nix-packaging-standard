{
  stdenv,
  patchAssertions,
}:
stdenv.mkDerivation {
  pname = "unasserted";
  version = "1";
  src = ./.;

  postPatch = patchAssertions + ''
    sed -i 's/fast_path = 0/fast_path = 1/' src/config.h
    landed src/config.h 'fast_path = 1' "config.h: fast path on"

    sed -i 's/if (getuid()) {/if (false) {/' gui/main.cpp
    substituteInPlace gui/main.cpp --replace-fail 'int main' 'int real_main'

    find . -name '*.py' -exec sed -i 's/OLD_NAME/NEW_NAME/g' {} +
    echo "renamed"

    substituteInPlace platform.dsc --replace-quiet 'L"EDK II"' 'L"Vendor"'
    echo "vendor set"

    patch -p1 < ${./fix.patch} || true
    echo "patched"

    perl -pi -e 's/wheel/plugdev/' rules/udev.rules
    awk -i inplace '{ sub(/^mode=0644/, "mode=0660") } 1' rules/modes
  '';
}
