{ lib, pkgs, git-fuse }:

pkgs.testers.nixosTest {
  name = "git-fuse-integration";

  meta = with lib.maintainers; {
    maintainers = [ ];
  };

  nodes.machine = { config, pkgs, ... }: {
    # Install git-fuse and dependencies
    environment.systemPackages = [ git-fuse pkgs.git ];

    # Ensure FUSE is available
    boot.kernelModules = [ "fuse" ];

    virtualisation = {
      memorySize = 1024;
    };
  };

  testScript = builtins.readFile ./test_script.py;
}
