import click

from cli.decorators import json_input_options
from cli.helpers import execute_command


@click.group()
def export():
    """Export commands (render photos to disk)."""
    pass


@export.command("files")
@click.option("--dest", required=True, help="Destination folder (absolute path on the Lightroom host)")
@click.option("--photo-ids", default=None, help="Comma-separated photo IDs (omit to use the current selection)")
@click.option(
    "--format",
    "fmt",
    type=click.Choice(["ORIGINAL", "JPEG", "TIFF", "PNG", "DNG", "PSD"], case_sensitive=False),
    default=None,
    help="Export format (default: ORIGINAL passthrough copy)",
)
@click.option("--quality", type=int, default=None, help="JPEG quality 0-100 (raster formats only)")
@click.option("--resize-long-edge", type=int, default=None, help="Resize long edge to N pixels (raster formats only)")
@click.option(
    "--overwrite",
    type=click.Choice(["skip", "overwrite", "rename"], case_sensitive=False),
    default=None,
    help="Existing-file behavior (default: rename)",
)
@click.option(
    "--continue-on-error/--stop-on-error",
    default=True,
    help="Continue past a photo that fails to render (default), or stop on the first failure",
)
@click.option("--dry-run", is_flag=True, default=False, help="Preview without executing")
@json_input_options
@click.pass_context
def export_files(ctx, dest, photo_ids, fmt, quality, resize_long_edge, overwrite, continue_on_error, dry_run, **kwargs):
    """Export photos to disk via LrExportSession (default ORIGINAL passthrough)."""
    params = {"dest": dest, "continueOnError": continue_on_error}
    if photo_ids is not None and photo_ids.strip():
        ids = [p.strip() for p in photo_ids.split(",") if p.strip()]
        if not ids:
            raise click.BadParameter("--photo-ids contained no valid IDs", param_hint="--photo-ids")
        params["photoIds"] = ids
    if fmt:
        params["format"] = fmt.upper()
    if quality is not None:
        params["quality"] = quality
    if resize_long_edge is not None:
        params["resizeLongEdge"] = resize_long_edge
    if overwrite:
        params["overwrite"] = overwrite.lower()
    execute_command(ctx, "catalog.exportPhotos", params, timeout=300.0)


@export.command("presets")
@click.option("--query", default=None, help="Filter presets by name or folder (case-insensitive)")
@json_input_options
@click.pass_context
def export_presets(ctx, query, **kwargs):
    """List export presets available in Lightroom."""
    params = {}
    if query:
        params["query"] = query
    execute_command(ctx, "catalog.listExportPresets", params)


@export.command("with-preset")
@click.option("--photo-ids", required=True, help="Comma-separated photo IDs")
@click.option("--preset", "preset_name", required=True, help="Export preset name (see `lr export presets`)")
@click.option("--output-dir", default=None, help="Override output directory (absolute path). Non-ASCII paths go to an ASCII staging dir; see stagingDir/finalOutputDir in the result")
@click.option("--dry-run", is_flag=True, default=False, help="Return photo count without exporting")
@json_input_options
@click.pass_context
def export_with_preset(ctx, photo_ids, preset_name, output_dir, dry_run, **kwargs):
    """Export photos using a named Lightroom export preset."""
    ids = [p.strip() for p in photo_ids.split(",") if p.strip()]
    if not ids:
        raise click.BadParameter("--photo-ids contained no valid IDs", param_hint="--photo-ids")
    params = {"photoIds": ids, "presetName": preset_name, "dryRun": dry_run}
    if output_dir:
        params["outputDir"] = output_dir
    execute_command(ctx, "catalog.exportWithPreset", params, timeout=600.0)
