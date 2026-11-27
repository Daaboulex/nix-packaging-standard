{
  stdenv,
  patchAssertions,
  writeShellApplication,
}:
stdenv.mkDerivation {
  pname = "asserted";
  version = "1";
  src = ./.;

  postPatch = patchAssertions + ''
    sed -i 's/if (getuid()) {/if (false) {/' gui/main.cpp
    landed gui/main.cpp 'if (false) {' "main.cpp: privilege check disabled"

    sed -i '/LogoDxe/d' platform.dsc platform.fdf
    # why: a comment between two edits and the check after them
    sed -i -E '/^static int probe\(/,/^}/{
      s/return 0;/return 1;/
    }' \
      src/probe.c
    gone platform.fdf LogoDxe "the logo driver is gone"

    find . -name '*.py' -exec sed -i 's/OLD_NAME/NEW_NAME/g' {} +
    if grep -rqF OLD_NAME --include='*.py' .; then
      exit 1
    fi

    perl -pi -e 's/wheel/plugdev/' rules/udev.rules
    grep -qF plugdev rules/udev.rules

    substituteInPlace platform.dsc --replace-quiet 'L"EDK II"' 'L"Vendor"'
    gone platform.dsc 'L"EDK II"' "no EDK II vendor left"

    sed -i 's/fast_path = 0/fast_path = 1/' src/config.h
    landed_soft src/config.h 'fast_path = 1' "optional fast path"

    for f in hw/usb/*.c; do
      sed -i '/usb_desc_create_serial(dev);/d' "$f"
    done
    if grep -qE 'sed -i|awk ' scripts/notes.txt; then
      echo "a mention of an edit is not an edit"
    fi
  '';

  postInstall = ''
    sed -i 's|^Exec=.*|Exec=asserted|' $out/share/applications/asserted.desktop
    sed -i "s|@out@|$out|" "$out/etc/asserted.conf"
  '';

  passthru.setOption = writeShellApplication {
    name = "set-option";
    text = ''
      sed -i "s|^option $2 .*|option $2 $3|" "$1"
    '';
  };
}
