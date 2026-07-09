"""catalog.applyDevelopPresetBatch のテスト (SDK 15.3 LrCatalog:applyDevelopPreset)"""

import pytest

from lightroom_sdk.client import LightroomClient
from lightroom_sdk.exceptions import LightroomSDKError


@pytest.mark.asyncio
async def test_apply_preset_batch_multiple_photos(mock_lr_server):
    """3枚の写真にプリセットを一括適用し、適用結果が返ること"""
    mock_lr_server.register_response(
        "catalog.applyDevelopPresetBatch",
        {
            "presetName": "Web書き出し用",
            "requested": 3,
            "applied": 3,
        },
    )
    async with LightroomClient(port_file=str(mock_lr_server.port_file)) as client:
        result = await client.execute_command(
            "catalog.applyDevelopPresetBatch",
            {"photoIds": [1, 2, 3], "presetName": "Web書き出し用"},
        )
    assert result["requested"] == 3
    assert result["applied"] == 3


@pytest.mark.asyncio
async def test_apply_preset_batch_partial_missing_photos(mock_lr_server):
    """一部のIDが見つからない場合、見つかった写真にのみ適用され missingPhotoIds が返ること"""
    mock_lr_server.register_response(
        "catalog.applyDevelopPresetBatch",
        {
            "presetName": "Web書き出し用",
            "requested": 3,
            "applied": 2,
            "missingPhotoIds": [999],
        },
    )
    async with LightroomClient(port_file=str(mock_lr_server.port_file)) as client:
        result = await client.execute_command(
            "catalog.applyDevelopPresetBatch",
            {"photoIds": [1, 999, 3], "presetName": "Web書き出し用"},
        )
    assert result["applied"] == 2
    assert result["missingPhotoIds"] == [999]


@pytest.mark.asyncio
async def test_apply_preset_batch_max_50_limit(mock_lr_server):
    """51枚指定でエラーが返ること"""
    mock_lr_server.register_response(
        "catalog.applyDevelopPresetBatch",
        {"error": {"code": "BATCH_SIZE_EXCEEDED", "message": "Maximum batch size is 50 photos"}},
    )
    async with LightroomClient(port_file=str(mock_lr_server.port_file)) as client:
        with pytest.raises(LightroomSDKError) as exc_info:
            await client.execute_command(
                "catalog.applyDevelopPresetBatch",
                {"photoIds": list(range(1, 52)), "presetName": "Web書き出し用"},
            )
    assert exc_info.value.code == "BATCH_SIZE_EXCEEDED"


@pytest.mark.asyncio
async def test_apply_preset_batch_preset_not_found(mock_lr_server):
    """存在しないプリセット名でエラーが返ること"""
    mock_lr_server.register_response(
        "catalog.applyDevelopPresetBatch",
        {"error": {"code": "PRESET_NOT_FOUND", "message": "Develop preset not found: Nonexistent"}},
    )
    async with LightroomClient(port_file=str(mock_lr_server.port_file)) as client:
        with pytest.raises(LightroomSDKError) as exc_info:
            await client.execute_command(
                "catalog.applyDevelopPresetBatch",
                {"photoIds": [1, 2], "presetName": "Nonexistent"},
            )
    assert exc_info.value.code == "PRESET_NOT_FOUND"


@pytest.mark.asyncio
async def test_apply_preset_batch_empty_photo_ids(mock_lr_server):
    """空の photoIds でエラー"""
    mock_lr_server.register_response(
        "catalog.applyDevelopPresetBatch",
        {"error": {"code": "MISSING_PHOTO_IDS", "message": "photoIds array is required"}},
    )
    async with LightroomClient(port_file=str(mock_lr_server.port_file)) as client:
        with pytest.raises(LightroomSDKError) as exc_info:
            await client.execute_command(
                "catalog.applyDevelopPresetBatch",
                {"photoIds": [], "presetName": "Web書き出し用"},
            )
    assert exc_info.value.code == "MISSING_PHOTO_IDS"
