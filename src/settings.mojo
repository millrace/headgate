"""settings — load headgate config from ~/.config/headgate/config.json + env.

Precedence, highest first:  environment variable  >  config file  >  built-in default.

The config file is JSON, parsed with the millrace `json` fork (dogfooding). Every
key is optional; a missing file or key falls back to env/defaults. Path override:
HEADGATE_CONFIG. Secrets (`anthropic_api_key`) are better supplied via the
ANTHROPIC_API_KEY env var than written to a plaintext file.

Recognized keys (all optional):
  local_url, local_model, remote_base_url, remote_model,
  remote_token_budget (int), anthropic_api_key, mock (bool), use_local_summary (bool)
"""

from std.os import getenv
from json import loads
from budget import parse_budget


struct Config(Movable):
    var local_url: String
    var local_model: String
    var remote_base_url: String
    var remote_model: String
    var remote_token_budget: Int
    var api_key: String
    var mock: Bool
    var use_local_summary: Bool

    def __init__(
        out self,
        var local_url: String,
        var local_model: String,
        var remote_base_url: String,
        var remote_model: String,
        remote_token_budget: Int,
        var api_key: String,
        mock: Bool,
        use_local_summary: Bool,
    ):
        self.local_url = local_url^
        self.local_model = local_model^
        self.remote_base_url = remote_base_url^
        self.remote_model = remote_model^
        self.remote_token_budget = remote_token_budget
        self.api_key = api_key^
        self.mock = mock
        self.use_local_summary = use_local_summary


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _env_or(key: String, var current: String) -> String:
    """`current` unless the env var `key` is set non-empty."""
    var v = getenv(key, "")
    return v if v != "" else current^


def config_path() -> String:
    return getenv("HEADGATE_CONFIG", getenv("HOME", "") + "/.config/headgate/config.json")


def load_config() -> Config:
    # 1. built-in defaults
    var local_url = String("http://127.0.0.1:8000/v1")
    var local_model = String("local")
    var remote_base_url = String("https://api.anthropic.com/v1")
    var remote_model = String("claude-sonnet-4-6")
    var token_budget = -1
    var api_key = String("")
    var mock = False
    var use_local_summary = False

    # 2. config file overrides defaults (best-effort: missing/bad file -> defaults)
    try:
        var j = loads(_read(config_path()))
        try: local_url = j["local_url"].string_value()
        except: pass
        try: local_model = j["local_model"].string_value()
        except: pass
        try: remote_base_url = j["remote_base_url"].string_value()
        except: pass
        try: remote_model = j["remote_model"].string_value()
        except: pass
        try: token_budget = Int(j["remote_token_budget"].int_value())
        except: pass
        try: api_key = j["anthropic_api_key"].string_value()
        except: pass
        try: mock = j["mock"].bool_value()
        except: pass
        try: use_local_summary = j["use_local_summary"].bool_value()
        except: pass
    except:
        pass

    # 3. environment variables override the config file
    local_url = _env_or("HEADGATE_LOCAL_URL", local_url^)
    local_model = _env_or("HEADGATE_LOCAL_MODEL", local_model^)
    remote_base_url = _env_or("ANTHROPIC_BASE_URL", remote_base_url^)
    remote_model = _env_or("HEADGATE_MODEL", remote_model^)
    api_key = _env_or("ANTHROPIC_API_KEY", api_key^)
    if getenv("HEADGATE_REMOTE_TOKEN_BUDGET", "") != "":
        token_budget = parse_budget(getenv("HEADGATE_REMOTE_TOKEN_BUDGET", ""))
    if getenv("HEADGATE_MOCK", "") != "":
        mock = True
    if getenv("HEADGATE_LOCAL", "") != "":
        use_local_summary = True

    return Config(local_url^, local_model^, remote_base_url^, remote_model^,
                  token_budget, api_key^, mock, use_local_summary)
