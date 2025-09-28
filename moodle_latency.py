#!/usr/bin/env python3
"""
Simple latency saver for Moodle crawler.

This module writes latency values to a separate Prometheus-style file
(`latency.prom`) so the existing metrics.prom is not changed.

The saver rotates the file when it exceeds max_size (default 10MB).
"""
import os
import logging
from datetime import datetime
from typing import List

logger = logging.getLogger(__name__)


class LatencySaver:
    """Handles saving latency metrics to Prometheus format file."""

    def __init__(self, output_dir: str, filename: str = 'latency.prom', max_size: int = 10 * 1024 * 1024) -> None:
        """
        Initialize the latency saver.

        Args:
            output_dir: Directory to save the latency file
            filename: Name of the latency file
            max_size: Maximum file size in bytes before rotation
        """
        self.output_dir = output_dir
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)

        self.filename = filename
        self.filepath = os.path.join(output_dir, filename)
        self.max_size = max_size
        self.metric_headers: List[str] = [
            '# HELP moodle_find_online_users_latency_milliseconds '
            'Latency (milliseconds) to locate the online users URL',
            '# TYPE moodle_find_online_users_latency_milliseconds gauge'
        ]

        if not os.path.exists(self.filepath):
            self._create_file_with_headers()

    def save_latency(self, latency_seconds: float, site_label: str) -> None:
        """Append a latency line (in milliseconds) to the latency file.

        Args:
            latency_seconds: Latency in seconds
            site_label: Site label (already sanitized)

        Raises:
            IOError: If file operations fail
        """
        try:
            metric_line = self._create_metric_line(latency_seconds, site_label)

            # Check file size and rotate if needed
            if self._should_rotate_file():
                logger.info(f"Latency file reached size limit, rotating")
                self._rotate_file()

            self._ensure_headers()

            with open(self.filepath, 'a') as f:
                f.write(metric_line + '\n')

            logger.debug(f"Wrote latency metric to {self.filepath}: {metric_line}")

        except Exception as e:
            logger.error(f"Error saving latency metric: {e}")
            raise IOError(f"Failed to save latency metric: {e}")

    def _create_metric_line(self, latency_seconds: float, site_label: str) -> str:
        """Create formatted metric line.

        Args:
            latency_seconds: Latency in seconds
            site_label: Site label

        Returns:
            Formatted metric line
        """
        # timestamp in milliseconds like the other metrics file
        timestamp_ms = int(datetime.now().timestamp() * 1000)
        # Convert seconds to milliseconds and record as integer milliseconds
        latency_ms = int(round(latency_seconds * 1000.0))
        return (
            f'moodle_find_online_users_latency_milliseconds{{site="{site_label}"}} '
            f'{latency_ms} {timestamp_ms}'
        )

    def _should_rotate_file(self) -> bool:
        """Check if file should be rotated.

        Returns:
            True if file should be rotated, False otherwise
        """
        if not os.path.exists(self.filepath):
            return False
        return os.path.getsize(self.filepath) >= self.max_size

    def _create_file_with_headers(self) -> None:
        """Create file with metric headers."""
        with open(self.filepath, 'w') as f:
            f.write('\n'.join(self.metric_headers) + '\n')

    def _rotate_file(self) -> None:
        """Rotate the latency file when it exceeds size limit.

        Raises:
            IOError: If file rotation fails
        """
        try:
            backup_file = self._generate_backup_filename()

            if os.path.exists(self.filepath):
                os.rename(self.filepath, backup_file)
                logger.info(f"Created latency backup: {backup_file}")

            # create new file with headers
            self._create_file_with_headers()

        except Exception as e:
            logger.error(f"Error rotating latency file: {e}")
            # Ensure file exists even if rotation fails
            if not os.path.exists(self.filepath):
                self._create_file_with_headers()
            raise IOError(f"File rotation failed: {e}")

    def _generate_backup_filename(self) -> str:
        """Generate backup filename with date and sequence number.

        Returns:
            Backup filename
        """
        current_date = datetime.now().strftime('%Y%m%d')
        backup_file = f"{self.filepath}.{current_date}.1"

        # If that exists, find a free index
        idx = 1
        while os.path.exists(backup_file):
            idx += 1
            backup_file = f"{self.filepath}.{current_date}.{idx}"

        return backup_file

    def _ensure_headers(self) -> None:
        """Ensure the latency file has proper headers.

        Raises:
            IOError: If header operations fail
        """
        try:
            if not os.path.exists(self.filepath):
                self._create_file_with_headers()
                return

            if not self._has_proper_headers():
                self._add_headers_to_existing_file()

        except Exception as e:
            logger.warning(f"Error ensuring latency headers: {e}")
            raise IOError(f"Failed to ensure headers: {e}")

    def _has_proper_headers(self) -> bool:
        """Check if file has proper headers.

        Returns:
            True if headers are present, False otherwise
        """
        try:
            with open(self.filepath, 'r') as f:
                first = next(f, '').strip()
                second = next(f, '').strip()
            return first.startswith('#') and second.startswith('#')
        except (IOError, StopIteration):
            return False

    def _add_headers_to_existing_file(self) -> None:
        """Add headers to existing file."""
        # Prepend headers while keeping existing content
        with open(self.filepath, 'r') as f:
            existing = f.read()
        with open(self.filepath, 'w') as f:
            f.write('\n'.join(self.metric_headers) + '\n')
            f.write(existing)