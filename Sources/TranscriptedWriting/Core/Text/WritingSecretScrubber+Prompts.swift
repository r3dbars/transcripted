import Foundation

/// Which typed lines start a password prompt in a terminal, and how the
/// answers after them are read. Split out of `WritingSecretScrubber.swift`;
/// `applyLineRules` there is the only caller.
extension WritingSecretScrubber {
    /// What a prompting command asks for: how many answer lines it can
    /// take, how many of those may be any one-word line (the rest have to
    /// repeat the first answer or look like a password on their own), and
    /// whether the first answer is a passphrase that may have spaces.
    struct Prompt {
        let answers: Int
        let looseAnswers: Int
        let passphrase: Bool

        /// `passwd`: old, new, confirm. Several answers is the protocol.
        static let passwordChange = Prompt(answers: 3, looseAnswers: 3, passphrase: false)
        /// `docker login`, `git clone https://…`: a username, then a password.
        static let usernameAndPassword = Prompt(answers: 2, looseAnswers: 2, passphrase: false)
        /// `sudo`: one password, then retries only when they look like one.
        static let elevation = Prompt(answers: 3, looseAnswers: 1, passphrase: false)
        /// `ssh`: one password, then retries (sshd asks 3 times) only when
        /// they look like one. With keys and agents most never ask.
        static let remoteLogin = Prompt(answers: 3, looseAnswers: 1, passphrase: false)
        /// `psql`, `kinit`: one password.
        static let single = Prompt(answers: 1, looseAnswers: 1, passphrase: false)
        /// `ssh-keygen`, `read -s`: a passphrase, then its confirmation.
        static let passphraseAndConfirm = Prompt(answers: 2, looseAnswers: 1, passphrase: true)

        func merged(with other: Prompt) -> Prompt {
            Prompt(
                answers: max(answers, other.answers),
                looseAnswers: max(looseAnswers, other.looseAnswers),
                passphrase: passphrase || other.passphrase
            )
        }
    }

    /// Commands and shell keywords a line after a prompt can start with when
    /// it's the next command, not a password (sudo had cached credentials, or
    /// the prompt never came).
    static let knownShellWords: Set<String> = [
        "ls", "ll", "la", "cd", "pwd", "clear", "cls", "exit", "logout", "whoami", "history", "top", "htop",
        "btop", "vim", "vi", "nvim", "nano", "emacs", "code", "cursor", "git", "gh", "brew", "npm", "npx",
        "yarn", "pnpm", "bun", "node", "deno", "python", "python3", "pip", "pip3", "uv", "ruby", "gem",
        "bundle", "rails", "swift", "swiftc", "xcodebuild", "xcrun", "make", "cmake", "cargo", "rustc",
        "go", "java", "mvn", "gradle", "docker", "podman", "kubectl", "k9s", "helm", "terraform", "cat",
        "bat", "less", "more", "tail", "head", "grep", "rg", "find", "fd", "echo", "printf", "man", "open",
        "which", "where", "type", "say", "tmux", "screen", "jobs", "fg", "bg", "kill", "killall", "pkill",
        "ps", "df", "du", "free", "uptime", "date", "cal", "env", "printenv", "export", "unset", "source",
        "alias", "bash", "zsh", "fish", "sh", "ssh", "sudo", "su", "mkdir", "rmdir", "rm", "cp", "mv",
        "touch", "chmod", "chown", "ln", "tar", "zip", "unzip", "gzip", "curl", "wget", "ping", "ifconfig",
        "ip", "netstat", "lsof", "uname", "sw_vers", "diskutil", "caffeinate", "pbcopy", "pbpaste",
        "mdfind", "defaults", "launchctl", "log", "claude", "codex", "reset", "reboot", "shutdown",
        "systemctl", "service", "journalctl", "quit", "apt", "apt-get", "yum", "dnf", "pacman", "fi", "done",
        "esac", "then", "else", "elif", "do", "end", "true", "false", "wait", "time", "watch", "tree",
        "wc", "sort", "uniq", "awk", "sed", "cut", "tr", "xargs", "diff", "patch", "stat", "file",
        // Dev tools people run bare, often right after ssh or a cached sudo.
        "pytest", "ruff", "mypy", "black", "isort", "tox", "nox", "poetry", "pipx", "conda", "jest",
        "vitest", "eslint", "prettier", "tsc", "turbo", "bazel", "ninja", "lazygit", "lazydocker", "tig",
        "fzf", "jq", "yq", "just", "ncdu", "ranger", "glances", "nvtop", "neofetch", "fastfetch",
        "zellij", "ollama", "rsync", "vagrant", "ansible", "pulumi", "gcloud",
    ]

    /// What `line`'s commands ask for, or `nil` when nothing on it prompts.
    static func promptingCommand(_ line: String) -> Prompt? {
        let asked = simpleCommands(in: line).compactMap(prompt(of:)).reduce(nil) { $0?.merged(with: $1) ?? $1 }
        guard runsDownloadedScript(line) else { return asked }
        return asked?.merged(with: .elevation) ?? .elevation
    }

    /// Split only executable shell separators. Quotes and substitutions belong
    /// to their word; a comment cannot introduce another executable command.
    static func shellCommands(in line: String) -> [(words: [String], piped: Bool)] {
        var result: [(words: [String], piped: Bool)] = []
        var words: [String] = [], word = ""
        var quote: Character?, escaped = false, depth = 0, piped = false
        var previous: Character?
        func finishWord() {
            if !word.isEmpty { words.append(word); word = "" }
        }
        func finishCommand() {
            finishWord()
            if !words.isEmpty { result.append((words, piped)); words = [] }
        }
        for character in line {
            defer { previous = character }
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { word.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "(", previous == "$" || previous == "<" || depth > 0 {
                depth += 1; word.append(character); continue
            }
            if character == ")", depth > 0 { depth -= 1; word.append(character); continue }
            if depth > 0 { word.append(character); continue }
            if character == "#", word.isEmpty { break }
            if character == ";" || character == "|" || character == "&" {
                finishCommand(); piped = character == "|" && previous != "|"; continue
            }
            if character.isWhitespace { finishWord() } else { word.append(character) }
        }
        if escaped { word.append("\\") }
        finishCommand()
        return result
    }

    static func simpleCommands(in line: String) -> [[String]] {
        shellCommands(in: line).map(\.words)
    }

    /// Commands that always prompt, by what they ask for.
    static let alwaysPrompting: [String: Prompt] = [
        "passwd": .passwordChange, "smbpasswd": .passwordChange, "vncpasswd": .passwordChange,
        "htpasswd": .passwordChange, "chpass": .passwordChange, "keytool": .passwordChange,
        "dscl": .passwordChange,
        "sudo": .elevation, "su": .elevation, "doas": .elevation, "sudoedit": .elevation, "pkexec": .elevation,
        "login": .usernameAndPassword, "telnet": .usernameAndPassword, "ftp": .usernameAndPassword,
        "fdesetup": .usernameAndPassword,
        "ssh": .remoteLogin, "scp": .remoteLogin, "sftp": .remoteLogin, "mosh": .remoteLogin, "kinit": .single,
        "psql": .single,
        "mysql_secure_installation": .single,
        "ssh-keygen": .passphraseAndConfirm, "ssh-add": .passphraseAndConfirm, "gpg": .passphraseAndConfirm,
        "gpg2": .passphraseAndConfirm, "openssl": .passphraseAndConfirm, "age": .passphraseAndConfirm,
    ]

    static let loginSubcommands: [String: (subcommands: Set<String>, prompt: Prompt)] = [
        "docker": (["login"], .usernameAndPassword), "podman": (["login"], .usernameAndPassword),
        "npm": (["login", "adduser"], .usernameAndPassword), "yarn": (["login"], .usernameAndPassword),
        "pnpm": (["login"], .usernameAndPassword), "vault": (["login"], .single), "op": (["signin"], .single),
        "security": (["unlock-keychain"], .single),
        "svn": (["checkout", "co", "commit", "update"], .usernameAndPassword),
        "hdiutil": (["attach"], .single), "aws": (["configure"], .usernameAndPassword),
        "diskutil": (["unlockvolume", "apfs"], .single),
    ]

    /// `git push` and friends ask only over an https remote with no
    /// credential helper; over ssh, or with a helper or the keychain, they
    /// don't. Only an http(s) URL on the line counts.
    static let remoteSubcommands: [String: Set<String>] = [
        "git": ["push", "pull", "clone", "fetch"], "hg": ["push", "pull", "clone"],
    ]

    /// Commands that run sudo themselves, so the password prompt comes with
    /// no `sudo` typed: Homebrew casks with a pkg installer, `make install`
    /// into a root-owned prefix. Answered like sudo. A next line that names
    /// the thing just installed is still redacted: it could be the password.
    static let indirectElevation: [String: Set<String>] = [
        "brew": ["install", "reinstall", "upgrade", "uninstall", "remove", "rm", "bundle"],
        "make": ["install", "uninstall"], "gmake": ["install", "uninstall"],
    ]

    static let shells: Set<String> = ["sh", "bash", "zsh"]

    /// `install.sh`, `./uninstall-tool.sh`, `setup_mac.sh`, `bootstrap.sh`:
    /// install scripts that call sudo partway through.
    static let installScriptPattern = regex(
        #"^(?:install|uninstall|setup|bootstrap)(?:[-_.][A-Za-z0-9]+)*\.sh$"#,
        caseInsensitive: true
    )

    /// A script fetched and run in one line, like Homebrew's own installer:
    /// `curl … | bash`, `bash -c "$(curl …)"`, `sh <(curl …)`. These often
    /// ask for the sudo password.
    static func runsDownloadedScript(_ line: String) -> Bool {
        let commands = shellCommands(in: line)
        for (index, segment) in commands.enumerated() {
            let words = invocationWords(segment.words)
            guard let first = words.first else { continue }
            let command = (first as NSString).lastPathComponent.lowercased()
            guard shells.contains(command), !shellSyntaxOnly(Array(words.dropFirst())) else { continue }
            if segment.piped, index > 0,
               let downloader = invocationWords(commands[index - 1].words).first,
               ["curl", "wget"].contains((downloader as NSString).lastPathComponent.lowercased()) {
                return true
            }
            // Only substitutions passed to an executing shell can feed it.
            let substitution = regex(#"(?:\$|<)\(\s*(?:curl|wget)\b"#)
            if words.dropFirst().contains(where: { firstMatch($0, substitution) != nil }) { return true }
        }
        return false
    }

    static func shellSyntaxOnly(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]; index += 1
            if argument == "--" || !argument.hasPrefix("-") { break }
            if !argument.hasPrefix("--"), argument.dropFirst().contains("n") { return true }
            if argument == "-c" || argument == "-s" { break }
            if !argument.hasPrefix("--"), argument.dropFirst().last == "o" || argument.dropFirst().last == "O" {
                if index < arguments.count {
                    if argument.dropFirst().last == "o", arguments[index] == "noexec" { return true }
                    index += 1
                }
            }
        }
        return false
    }

    static func shellScript(_ arguments: [String]) -> String? {
        guard !shellSyntaxOnly(arguments) else { return nil }
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]; index += 1
            if argument == "--" { return index < arguments.count ? arguments[index] : nil }
            if argument.hasPrefix("-") {
                if argument == "-c" || argument == "-s" { return nil }
                if !argument.hasPrefix("--"), argument.dropFirst().last == "o" || argument.dropFirst().last == "O" {
                    if index < arguments.count { index += 1 }
                }
                continue
            }
            return argument
        }
        return nil
    }

    static func makeNonexecutingShortOption(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { return false }
        for option in argument.dropFirst() {
            if "nqt".contains(option) { return true }
            // These take an operand, possibly attached; its letters are not flags.
            if "CfIjloW".contains(option) || !option.isLetter { return false }
        }
        return false
    }

    /// A brew, make or install-script command (`indirectElevation`,
    /// `installScriptPattern`): it may run sudo, or may not ask at all.
    static func asksSudoItself(_ command: String, _ arguments: [String]) -> Bool {
        let sub = arguments.first(where: { !$0.hasPrefix("-") })?.lowercased()
        if command == "make" || command == "gmake" {
            let valueOptions: Set<String> = ["-C", "--directory", "-f", "--file", "--makefile", "-I", "--include-dir", "-j", "--jobs", "-l", "--load-average", "-o", "--old-file", "--assume-old", "-W", "--what-if", "--new-file", "--assume-new", "--eval"]
            var index = 0
            var installTarget = false
            while index < arguments.count {
                let argument = arguments[index]
                index += 1
                if ["--just-print", "--dry-run", "--recon", "--question", "--touch"].contains(argument) ||
                    makeNonexecutingShortOption(argument) {
                    return false
                }
                if valueOptions.contains(argument) {
                    // -j and -l may omit a numeric value.
                    if ["-j", "--jobs", "-l", "--load-average"].contains(argument) {
                        if index < arguments.count, Double(arguments[index]) != nil { index += 1 }
                    } else if index < arguments.count { index += 1 }
                    continue
                }
                if argument.hasPrefix("-") || argument.contains("=") { continue }
                if indirectElevation[command]?.contains(argument.lowercased()) == true { installTarget = true }
            }
            return installTarget
        }
        if let subcommands = indirectElevation[command], let sub, subcommands.contains(sub) { return true }
        let script = shells.contains(command) ? shellScript(arguments).map { ($0 as NSString).lastPathComponent } : command
        return script.map { matchesWhole($0.trimmingCharacters(in: CharacterSet(charactersIn: "\"\'")), installScriptPattern) } ?? false
    }

    static let commandPrefixes: Set<String> = ["time", "env", "nohup", "command", "exec", "builtin", "caffeinate"]

    /// Peel command wrappers and environment assignments before identifying
    /// the executable, including env's value-bearing options.
    static func invocationWords(_ words: [String]) -> ArraySlice<String> {
        var remaining = words[...]
        while let first = remaining.first {
            let command = (first as NSString).lastPathComponent
            if first.contains("=") && !first.hasPrefix("-") { remaining = remaining.dropFirst(); continue }
            guard commandPrefixes.contains(command) else { break }
            remaining = remaining.dropFirst()
            if command == "env" {
                while let option = remaining.first, option.hasPrefix("-") {
                    remaining = remaining.dropFirst()
                    if ["-u", "--unset", "-C", "--chdir"].contains(option), !remaining.isEmpty { remaining = remaining.dropFirst() }
                    if option == "--" { break }
                }
            }
        }
        return remaining
    }

    static func prompt(of words: [String]) -> Prompt? {
        let remaining = invocationWords(words)
        guard let first = remaining.first else { return nil }
        let command = (first.split(separator: "/").last.map(String.init) ?? first).lowercased()
        let arguments = Array(remaining.dropFirst())
        if let prompt = alwaysPrompting[command] { return prompt }
        if ["mysql", "mariadb", "mysqldump", "mysqladmin"].contains(command) {
            return arguments.contains("-p") || arguments.contains("--password") ? .single : nil
        }
        if command == "read" {
            let silent = arguments.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("s") }
            return silent ? .passphraseAndConfirm : nil
        }
        if command.hasPrefix("ansible") {
            // One prompt per flag: the SSH password, then the become password.
            let asks = arguments.filter { ["--ask-pass", "--ask-become-pass", "-k", "-K"].contains($0) }.count
            return asks == 0 ? nil : asks == 1 ? .single : .usernameAndPassword
        }
        if command == "gh", arguments.prefix(2) == ["auth", "login"] { return .single }
        let sub = arguments.first(where: { !$0.hasPrefix("-") })?.lowercased()
        if asksSudoItself(command, arguments) { return .elevation }
        if let login = loginSubcommands[command], let sub, login.subcommands.contains(sub) {
            return login.prompt
        }
        if let subcommands = remoteSubcommands[command], let sub, subcommands.contains(sub),
           arguments.contains(where: { $0.lowercased().hasPrefix("https://") || $0.lowercased().hasPrefix("http://") }) {
            return .usernameAndPassword
        }
        return nil
    }

    // MARK: Values the standalone rule used to skip

    /// `$unsh1ne`, `$Ecret99`: a password that starts with `$`, not a shell
    /// variable (`$HOME`, `$db_pass`, `${TOKEN}`) or an amount (`$120k`).
    static func isDollarValue(_ line: String) -> Bool {
        guard line.hasPrefix("$"), let second = line.dropFirst().first, second.isLetter else { return false }
        if matchesWhole(line, regex(#"^\$[A-Za-z_][A-Za-z0-9_]*$"#)), !isLeetCommonPassword(line) { return false }
        return !isPlaceholderOrCode(line)
    }
}
