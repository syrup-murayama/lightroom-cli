import asyncio
import json

import pytest

import lightroom_sdk.socket_bridge as socket_bridge
from lightroom_sdk.socket_bridge import SocketBridge


@pytest.mark.asyncio
async def test_on_event_registers_and_fires(mock_lr_server):
    """on_event()で登録したハンドラがイベント受信時に呼ばれる"""
    received = []

    bridge = SocketBridge(port_file=str(mock_lr_server.port_file))
    bridge.on_event("photo.selected", lambda data: received.append(data))

    await bridge.connect(retry_attempts=1)
    await mock_lr_server.wait_for_client()

    # MockServerからイベント送信
    await mock_lr_server.send_event("photo.selected", {"photoId": "123"})
    await asyncio.sleep(0.3)

    assert len(received) == 1
    assert received[0]["photoId"] == "123"
    await bridge.disconnect()


@pytest.mark.asyncio
async def test_unregistered_event_ignored(mock_lr_server):
    """未登録イベントがエラーにならないことを検証"""
    bridge = SocketBridge(port_file=str(mock_lr_server.port_file))
    await bridge.connect(retry_attempts=1)
    await mock_lr_server.wait_for_client()

    await mock_lr_server.send_event("unknown.event", {})
    await asyncio.sleep(0.3)
    # エラーが発生しなければOK

    await bridge.disconnect()


@pytest.mark.asyncio
async def test_send_command_serializes_requests_as_utf8(monkeypatch):
    """Python→Lua requests keep non-ASCII path text as UTF-8, not JSON \\u escapes."""
    dumps_calls = []
    original_dumps = json.dumps

    def dumps_spy(obj, *args, **kwargs):
        dumps_calls.append(kwargs.copy())
        return original_dumps(obj, *args, **kwargs)

    class FakeWriter:
        def __init__(self, bridge):
            self.bridge = bridge
            self.payload = b""

        def write(self, data):
            self.payload += data
            message = json.loads(data.decode("utf-8"))
            self.bridge._pending_requests[message["id"]].set_result(
                {"id": message["id"], "success": True, "result": {"ok": True}}
            )

        async def drain(self):
            pass

    bridge = SocketBridge.__new__(SocketBridge)
    bridge._connected = True
    bridge._pending_requests = {}
    bridge._pending_streams = {}
    bridge._send_writer = FakeWriter(bridge)

    monkeypatch.setattr(socket_bridge.json, "dumps", dumps_spy)

    response = await bridge.send_command(
        "catalog.exportWithPreset",
        {"outputDir": "/Users/daisuke/Pictures/暁/export"},
    )

    assert response["success"] is True
    assert dumps_calls[0]["ensure_ascii"] is False
    assert "暁" in bridge._send_writer.payload.decode("utf-8")
    assert "\\u6681" not in bridge._send_writer.payload.decode("utf-8")
