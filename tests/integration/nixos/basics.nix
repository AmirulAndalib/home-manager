{ pkgs, ... }:

{
  name = "nixos-basics";
  meta.maintainers = [ pkgs.lib.maintainers.rycee ];

  nodes.machine =
    { ... }:
    {
      imports = [ ../../../nixos ]; # Import the HM NixOS module.

      virtualisation.memorySize = 2048;

      users.users.alice = {
        isNormalUser = true;
        description = "Alice Foobar";
        password = "foobar";
        uid = 1000;
      };

      home-manager.users.alice =
        { ... }:
        {
          home.stateVersion = "24.11";
          home.file.test.text = "testfile";
          # Enable a light-weight systemd service.
          services.pueue.enable = true;
        };
    };

  testScript = ''
    def login_as_alice():
      machine.wait_until_tty_matches("1", "login: ")
      machine.send_chars("alice\n")
      machine.wait_until_tty_matches("1", "Password: ")
      machine.send_chars("foobar\n")
      machine.wait_until_tty_matches("1", "alice\\@machine")

    def logout_alice():
      machine.send_chars("exit\n")

    def alice_cmd(cmd):
      return f"su -l alice --shell /bin/sh -c $'export XDG_RUNTIME_DIR=/run/user/$UID ; {cmd}'"

    def succeed_as_alice(cmd):
      return machine.succeed(alice_cmd(cmd))

    def fail_as_alice(cmd):
      return machine.fail(alice_cmd(cmd))

    start_all()

    machine.wait_for_console_text("Finished Home Manager environment for alice.")

    with subtest("Home Manager file"):
      # The file should be linked with the expected content.
      path = "/home/alice/test"
      machine.succeed(f"test -L {path}")
      actual = machine.succeed(f"cat {path}")
      expected = "testfile"
      assert actual == expected, f"expected {path} to contain {expected}, but got {actual}"

    with subtest("Pueue service"):
      login_as_alice()

      actual = succeed_as_alice("pueue status")
      expected = "running"
      assert expected in actual, f"expected pueue status to contain {expected}, but got {actual}"

      # Shut down pueue, then run the activation again. Afterwards, the service
      # should be running.
      machine.succeed("systemctl --user -M alice@.host stop pueued.service")

      fail_as_alice("pueue status")

      machine.systemctl("restart home-manager-alice.service")
      machine.wait_for_console_text("Finished Home Manager environment for alice.")

      actual = succeed_as_alice("pueue status")
      expected = "running"
      assert expected in actual, f"expected pueue status to contain {expected}, but got {actual}"

      logout_alice()

    with subtest("no profile management"):
      # There should be no Home Manager profile since we are not
      # using legacy profile management.
      hmProfile = "/home/alice/.local/state/nix/profiles/home-manager"
      machine.succeed(f"test ! -e {hmProfile}")

      # There should be a gcroot, however since we want to keep track of which
      # generation is currently enabled.
      hmGcroot = "/home/alice/.local/state/home-manager/gcroots/current-home"
      machine.succeed(f"test -e {hmGcroot}")
  '';
}
