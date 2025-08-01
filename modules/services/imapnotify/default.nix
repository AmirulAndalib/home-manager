{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    listToAttrs
    optionalAttrs
    ;

  cfg = config.services.imapnotify;

  safeName = lib.replaceStrings [ "@" ":" "\\" "[" "]" ] [ "-" "-" "-" "" "" ];

  configName = account: "imapnotify-${safeName account.name}-config.json";

  imapnotifyAccounts = lib.filter (a: a.imapnotify.enable) (
    lib.attrValues config.accounts.email.accounts
  );

  genAccountUnit =
    account:
    let
      name = safeName account.name;
    in
    {
      name = "imapnotify-${name}";
      value = {
        Unit = {
          Description = "imapnotify for ${name}";
        };

        Service = {
          # Use the nix store path for config to ensure service restarts when it changes
          ExecStart =
            "${lib.getExe cfg.package} -conf '${genAccountConfig account}'"
            + " ${lib.optionalString (account.imapnotify.extraArgs != [ ]) (
               toString account.imapnotify.extraArgs
             )}";
          Restart = "always";
          RestartSec = 30;
          Type = "simple";
          Environment = [
            "PATH=${cfg.path}"
          ]
          ++ lib.optional account.notmuch.enable "NOTMUCH_CONFIG=${config.xdg.configHome}/notmuch/default/config";
        };

        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    };

  genAccountAgent =
    account:
    let
      name = safeName account.name;
    in
    {
      name = "imapnotify-${name}";
      value = {
        enable = true;
        config = {
          # Use the nix store path for config to ensure service restarts when it changes
          ProgramArguments = [
            "${lib.getExe cfg.package}"
            "-conf"
            "${genAccountConfig account}"
          ];
          KeepAlive = true;
          ThrottleInterval = 30;
          ExitTimeOut = 0;
          ProcessType = "Background";
          RunAtLoad = true;
        }
        // optionalAttrs account.notmuch.enable {
          EnvironmentVariables.NOTMUCH_CONFIG = "${config.xdg.configHome}/notmuch/default/config";
        };
      };
    };

  genAccountConfig =
    account:
    pkgs.writeText (configName account) (
      let
        port =
          if account.imap.port != null then
            account.imap.port
          else if account.imap.tls.enable then
            993
          else
            143;

        toJSON = builtins.toJSON;
      in
      toJSON (
        {
          inherit (account.imap) host;
          inherit port;
          tls = account.imap.tls.enable;
          tlsOptions.starttls = account.imap.tls.useStartTls;
          username = account.userName;
          passwordCmd = lib.concatMapStringsSep " " lib.escapeShellArg account.passwordCommand;
          inherit (account.imapnotify) boxes;
        }
        // optionalAttrs (account.imapnotify.onNotify != "") {
          onNewMail = account.imapnotify.onNotify;
        }
        // optionalAttrs (account.imapnotify.onNotifyPost != "") {
          onNewMailPost = account.imapnotify.onNotifyPost;
        }
        // account.imapnotify.extraConfig
      )
    );

in
{
  meta.maintainers = [ lib.maintainers.nickhu ];

  options = {
    services.imapnotify = {
      enable = lib.mkEnableOption "imapnotify";

      package = lib.mkPackageOption pkgs "goimapnotify" {
        example = "pkgs.imapnotify";
      };

      path = mkOption {
        type = types.listOf types.package;
        apply = lib.makeBinPath;
        default = [ ];
        description = ''
          List of packages to provide in PATH for the imapnotify service.

          Note, this does not apply to the Darwin launchd service.
        '';
      };
    };

    accounts.email.accounts = mkOption {
      type = with types; attrsOf (submodule (import ./accounts.nix { inherit pkgs lib; }));
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      let
        checkAccounts =
          pred: msg:
          let
            badAccounts = lib.filter pred imapnotifyAccounts;
          in
          {
            assertion = badAccounts == [ ];
            message =
              "imapnotify: Missing ${msg} for accounts: " + lib.concatMapStringsSep ", " (a: a.name) badAccounts;
          };
      in
      [
        (checkAccounts (a: a.maildir == null) "maildir configuration")
        (checkAccounts (a: a.imap == null) "IMAP configuration")
        (checkAccounts (a: a.passwordCommand == null) "password command")
        (checkAccounts (a: a.userName == null) "username")
      ];

    services.imapnotify.path = lib.mkMerge [
      (lib.mkIf config.programs.notmuch.enable [ pkgs.notmuch ])
      (lib.mkIf config.programs.mbsync.enable [ config.programs.mbsync.package ])
    ];

    systemd.user.services = listToAttrs (map genAccountUnit imapnotifyAccounts);

    launchd.agents = listToAttrs (map genAccountAgent imapnotifyAccounts);

    xdg.configFile = listToAttrs (
      map (account: {
        name = "imapnotify/${configName account}";
        value.source = genAccountConfig account;
      }) imapnotifyAccounts
    );
  };
}
