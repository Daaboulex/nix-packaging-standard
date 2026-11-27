{
  meta = {
    reason = "pinned reads a pin of its own, which has no use once the fix heals";
    added = "2026-11-27";
    owns = [ "pin.json" ];
  };
  dropWhen = _pkgs: false;
  overlay = _final: _prev: {
    pin = (builtins.fromJSON (builtins.readFile ../pin.json)).rev;
  };
}
