# The boot splash theme: two generated PNGs and forty lines of plymouth
# script. See splash-images.py for the mark and pesmarica.script for what it
# does with it.
#
# ImageDir and ScriptFile have to be absolute paths into this store path,
# because the NixOS plymouth module rewrites exactly that shape when it copies
# the theme into the initrd: it seds everything up to /share/plymouth/themes
# into the initrd's own directory. A relative path would survive the copy and
# then point at nothing.
{ runCommand, python3 }:

runCommand "plymouth-theme-pesmarica" { nativeBuildInputs = [ python3 ]; } ''
  dir=$out/share/plymouth/themes/pesmarica
  mkdir -p "$dir"

  python3 ${./splash-images.py} "$dir"
  cp ${./pesmarica.script} "$dir/pesmarica.script"

  {
    echo "[Plymouth Theme]"
    echo "Name=Pesmarica"
    echo "Description=The songbook's mark, on the panel it will keep"
    echo "ModuleName=script"
    echo
    echo "[script]"
    echo "ImageDir=$dir"
    echo "ScriptFile=$dir/pesmarica.script"
  } > "$dir/pesmarica.plymouth"
''
