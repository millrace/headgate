"""local-probe — runtime-verify LocalClient's flare HTTP path.

Calls LocalClient.chat against a local OpenAI-shaped server (see
.scratch/local_server.py on :8799) and prints the assistant content. Proves the
plain-HTTP client path (flare HttpClient POST -> Response.json() -> Value access)
works end to end, without needing a real inference-server.
"""

from transport import LocalClient, ChatMessage


def main() raises:
    var c = LocalClient(String("http://127.0.0.1:8799"), String("local"))
    var msgs = List[ChatMessage]()
    msgs.append(ChatMessage(String("system"), String("be terse")))
    msgs.append(ChatMessage(String("user"), String("say hi")))
    var reply = c.chat(msgs)
    print("LOCAL REPLY:", reply)
    if reply == "hi from the local model":
        print("LOCAL HTTP OK")
    else:
        raise Error("unexpected local reply: " + reply)
