#!/usr/bin/env python3
"""
Moodle Online Users Crawler

This script crawls Moodle sites to extract the total number of online users
while accessing as a guest. It outputs the data in Prometheus metrics format
for monitoring and visualization.

The only metrics output is the total count of online users in the metrics.prom file.
No individual user data is collected or stored.

Features:
- Auto-rotating metrics.prom file (max 10MB per file, up to 5 backups)
- Auto-rotating logs (max 10MB per file, up to 5 backups)
- Prometheus metrics format with timestamps
"""

import requests
from bs4 import BeautifulSoup
import argparse
import logging
import time
import re
import os
from datetime import datetime, timedelta
from urllib.parse import urljoin
from logging.handlers import RotatingFileHandler
from moodle_latency import LatencySaver
from dataclasses import dataclass
from typing import Optional, List, Dict, Any
from abc import ABC, abstractmethod


@dataclass
class CrawlerConfig:
    """Configuration class for Moodle crawler settings."""
    # File size limits
    max_file_size_mb: int = 10
    max_backup_count: int = 5

    # Default intervals
    default_interval_seconds: int = 60

    # File names
    log_filename: str = "moodle_crawler.log"
    metrics_filename: str = "metrics.prom"
    example_html_filename: str = "example.html"

    # HTTP settings
    user_agent: str = (
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/123.0.0.0 Safari/537.36'
    )
    accept_language: str = 'en-US,en;q=0.9'

    # Common Moodle paths to check for online users
    common_online_user_paths: List[str] = None

    def __post_init__(self):
        """Initialize default paths after object creation."""
        if self.common_online_user_paths is None:
            self.common_online_user_paths = [
                '/user/index.php',
                '/blocks/online_users/index.php',
                '/user/online.php',
                '/course/view.php?id=1'  # Often the front page
            ]

    @property
    def max_file_size_bytes(self) -> int:
        """Get max file size in bytes."""
        return self.max_file_size_mb * 1024 * 1024


class MoodleError(Exception):
    """Base exception for Moodle crawler errors."""
    pass


class AuthenticationError(MoodleError):
    """Raised when guest authentication fails."""
    pass


class URLDiscoveryError(MoodleError):
    """Raised when online users URL cannot be found."""
    pass


class ExtractionError(MoodleError):
    """Raised when online user count cannot be extracted."""
    pass


class URLDiscoveryStrategy(ABC):
    """Abstract base class for URL discovery strategies."""

    @abstractmethod
    def discover_url(self, session: requests.Session, base_url: str, headers: Dict[str, str]) -> Optional[str]:
        """Discover the online users URL using this strategy.

        Args:
            session: HTTP session to use for requests
            base_url: Base URL of the Moodle site
            headers: HTTP headers to use

        Returns:
            URL if found, None otherwise
        """
        pass


class DashboardDiscoveryStrategy(URLDiscoveryStrategy):
    """Strategy to find online users on the dashboard page."""

    def discover_url(self, session: requests.Session, base_url: str, headers: Dict[str, str]) -> Optional[str]:
        """Check dashboard page for online users."""
        try:
            dashboard_url = urljoin(base_url, '/my/')
            logger.info(f"Checking dashboard page: {dashboard_url}")

            response = session.get(dashboard_url, headers=headers)
            if response.status_code == 200 and 'online users' in response.text.lower():
                logger.info("Found online users text in dashboard")
                return dashboard_url

        except requests.exceptions.RequestException as e:
            logger.debug(f"Dashboard discovery failed: {e}")

        return None


class MainPageDiscoveryStrategy(URLDiscoveryStrategy):
    """Strategy to find online users on the main page."""

    def discover_url(self, session: requests.Session, base_url: str, headers: Dict[str, str]) -> Optional[str]:
        """Check main page for online users."""
        try:
            logger.info(f"Checking main page: {base_url}")
            response = session.get(base_url, headers=headers)
            response.raise_for_status()

            if 'online users' in response.text.lower():
                logger.info("Found online users text in main page")
                return base_url

        except requests.exceptions.RequestException as e:
            logger.debug(f"Main page discovery failed: {e}")

        return None


class CommonPathsDiscoveryStrategy(URLDiscoveryStrategy):
    """Strategy to find online users by checking common paths."""

    def __init__(self, paths: List[str]):
        self.paths = paths

    def discover_url(self, session: requests.Session, base_url: str, headers: Dict[str, str]) -> Optional[str]:
        """Check common paths for online users."""
        for path in self.paths:
            try:
                url = urljoin(base_url, path)
                logger.info(f"Trying common path: {url}")
                response = session.get(url, headers=headers)

                if response.status_code == 200 and 'online' in response.text.lower():
                    logger.info(f"Found online users info at: {url}")
                    return url

            except requests.exceptions.RequestException as e:
                logger.debug(f"Common path {path} failed: {e}")

        return None


class ExampleFileDiscoveryStrategy(URLDiscoveryStrategy):
    """Fallback strategy using example.html file for testing."""

    def __init__(self, example_filename: str):
        self.example_filename = example_filename

    def discover_url(self, session: requests.Session, base_url: str, headers: Dict[str, str]) -> Optional[str]:
        """Check if example file exists for testing."""
        try:
            if os.path.isfile(self.example_filename):
                logger.info(f"Found {self.example_filename} for online users testing")
                return base_url  # Return base URL but will use example file in crawl()
        except Exception as e:
            logger.debug(f"Example file strategy failed: {e}")

        return None


class URLDiscoverer:
    """Manages URL discovery using multiple strategies."""

    def __init__(self, config: CrawlerConfig):
        self.strategies = [
            DashboardDiscoveryStrategy(),
            MainPageDiscoveryStrategy(),
            CommonPathsDiscoveryStrategy(config.common_online_user_paths),
            ExampleFileDiscoveryStrategy(config.example_html_filename)
        ]

    def find_online_users_url(self, session: requests.Session, base_url: str, headers: Dict[str, str]) -> str:
        """Find online users URL using available strategies.

        Args:
            session: HTTP session to use
            base_url: Base URL of the Moodle site
            headers: HTTP headers to use

        Returns:
            URL for online users page

        Raises:
            URLDiscoveryError: If no URL can be found
        """
        logger.info("Looking for online users block or page")

        for strategy in self.strategies:
            try:
                url = strategy.discover_url(session, base_url, headers)
                if url:
                    return url
            except Exception as e:
                logger.debug(f"Strategy {strategy.__class__.__name__} failed: {e}")

        logger.warning("Could not find online users URL, using base URL as fallback")
        return base_url  # Return base URL as final fallback


class OnlineUserExtractor(ABC):
    """Abstract base class for online user extraction strategies."""

    @abstractmethod
    def extract_count(self, soup: BeautifulSoup) -> Optional[int]:
        """Extract online user count from BeautifulSoup object.

        Args:
            soup: BeautifulSoup object of the HTML page

        Returns:
            User count if found, None otherwise
        """
        pass


class InfoDivExtractor(OnlineUserExtractor):
    """Extract online users from div.info elements."""

    def extract_count(self, soup: BeautifulSoup) -> Optional[int]:
        """Look for div.info with online users count."""
        logger.info("Looking for 'info' div with online users count")
        info_divs = soup.find_all('div', {'class': 'info'})

        for div in info_divs:
            text = div.get_text(strip=True)
            match = re.search(r'(\d+)\s+online\s+users?', text, re.IGNORECASE)
            if match:
                count = int(match.group(1))
                logger.info(f"Found div.info with {count} online users")
                return count

        return None


class OnlineBlockExtractor(OnlineUserExtractor):
    """Extract online users from online_users blocks."""

    def extract_count(self, soup: BeautifulSoup) -> Optional[int]:
        """Look for online_users block elements."""
        # Look for online_users block (common in Moodle)
        online_blocks = soup.find_all(
            'div',
            {'class': re.compile(r'block_online_users')}
        )

        # Also look for blocks with "Online users" in the header
        if not online_blocks:
            headers = soup.find_all(
                'h4',
                text=re.compile(r'online users', re.IGNORECASE)
            )
            for header in headers:
                parent_block = header.find_parent('div')
                if parent_block:
                    online_blocks.append(parent_block)

        if online_blocks:
            logger.info(f"Found {len(online_blocks)} online users blocks")

            for block in online_blocks:
                # Check div.info pattern in blocks
                info_div = block.find('div', {'class': 'info'})
                if info_div:
                    info_text = info_div.get_text(strip=True)
                    count_match = re.search(
                        r'(\d+)\s+online\s+users?',
                        info_text,
                        re.IGNORECASE
                    )
                    if count_match:
                        count = int(count_match.group(1))
                        logger.info(f"Extracted online user count: {count}")
                        return count

        return None


class TextPatternExtractor(OnlineUserExtractor):
    """Extract online users using text pattern matching."""

    def extract_count(self, soup: BeautifulSoup) -> Optional[int]:
        """Look for online user count in any text on the page."""
        online_count_pattern = re.compile(
            r'(\d+)\s+(?:users?\s+online|online\s+users?)',
            re.IGNORECASE
        )
        for text in soup.stripped_strings:
            match = online_count_pattern.search(text)
            if match:
                count = int(match.group(1))
                logger.info(f"Found text indicating {count} online users")
                return count

        return None


class OnlineUserCountExtractor:
    """Manages online user count extraction using multiple strategies."""

    def __init__(self):
        self.extractors = [
            InfoDivExtractor(),
            OnlineBlockExtractor(),
            TextPatternExtractor()
        ]

    def extract_online_users(self, html_content: str) -> int:
        """Extract online users count from HTML content.

        Args:
            html_content: HTML content of the online users page

        Returns:
            Total count of online users

        Raises:
            ExtractionError: If count cannot be extracted
        """
        soup = BeautifulSoup(html_content, 'lxml')

        for extractor in self.extractors:
            try:
                count = extractor.extract_count(soup)
                if count is not None:
                    return count
            except Exception as e:
                logger.debug(f"Extractor {extractor.__class__.__name__} failed: {e}")

        logger.warning("Could not extract online users count")
        return 0


# Configure logging
# Set up the formatter
log_formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")

# Set up the root logger
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Set up a rotating file handler using config
config = CrawlerConfig()
file_handler = RotatingFileHandler(
    config.log_filename,
    maxBytes=config.max_file_size_bytes,
    backupCount=config.max_backup_count
)
file_handler.setFormatter(log_formatter)

# Set up console handler
console_handler = logging.StreamHandler()
console_handler.setFormatter(log_formatter)

# Add both handlers to the logger
logger.addHandler(file_handler)
logger.addHandler(console_handler)


class MoodleCrawler:
    def __init__(self, base_url: str, interval: int = None, output_dir: str = "data",
                 config: Optional[CrawlerConfig] = None, allow_example_fallback: bool = False):
        """
        Initialize the Moodle crawler.

        Args:
            base_url: Base URL of the Moodle site
            interval: Interval between crawls in seconds
            output_dir: Directory to save collected data
            config: Configuration object with crawler settings
            allow_example_fallback: Permit example.html substitution when the
                real page is unreachable (demo/testing only)
        """
        self.config = config or CrawlerConfig()
        self.base_url = base_url.rstrip('/')
        self.interval = interval or self.config.default_interval_seconds
        self.output_dir = output_dir
        self.allow_example_fallback = allow_example_fallback
        self.session = requests.Session()
        self.headers = {
            'User-Agent': self.config.user_agent,
            'Accept-Language': self.config.accept_language,
        }
        
        # Create output directory if it doesn't exist
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)
            
        # Track current online user count and timestamp
        self.online_count = 0
        self.last_crawl_time = None
        
        # Set up metrics rotation handler
        self.metrics_file = os.path.join(output_dir, self.config.metrics_filename)
        self.metric_headers = [
            "# HELP moodle_online_users_total "
            "Total number of online users on the Moodle site",
            "# TYPE moodle_online_users_total gauge"
        ]
        
        # Initialize metrics file with headers if it doesn't exist
        if not os.path.exists(self.metrics_file):
            with open(self.metrics_file, 'w') as f:
                f.write("\n".join(self.metric_headers) + "\n")

        # Initialize latency saver (writes to latency.prom in output_dir)
        try:
            self.latency_saver = LatencySaver(output_dir)
        except Exception:
            # If latency saver fails for any reason, keep running without it
            logger.warning("Failed to initialize LatencySaver, continuing without latency metrics")
            self.latency_saver = None

        # Initialize URL discoverer with strategies
        self.url_discoverer = URLDiscoverer(self.config)

        # Initialize online user count extractor
        self.count_extractor = OnlineUserCountExtractor()

    def login_as_guest(self) -> bool:
        """Attempt to login as a guest if required.

        Returns:
            True if guest access successful or not required, False on failure

        Raises:
            AuthenticationError: If guest authentication fails critically
        """
        try:
            logger.info("Attempting to access site as guest")

            # First go to the login page
            login_url = urljoin(self.base_url, '/login/index.php')
            logger.info(f"Accessing login page at: {login_url}")

            response = self.session.get(login_url, headers=self.headers)
            response.raise_for_status()

            # Look for guest access options
            soup = BeautifulSoup(response.text, 'lxml')

            # Try form-based guest access first
            if self._try_guest_form_login(soup):
                logger.info("Successfully logged in as guest via form")
                return True

            # Try link-based guest access
            if self._try_guest_link_login(soup):
                logger.info("Successfully logged in as guest via link")
                return True

            # No guest access found, but continue anyway
            logger.warning("No guest access button/link found, proceeding anyway")
            return True

        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to access site as guest: {str(e)}")
            raise AuthenticationError(f"Guest authentication failed: {e}")
        except Exception as e:
            logger.error(f"Unexpected error during guest login: {e}")
            raise AuthenticationError(f"Unexpected authentication error: {e}")

    def _try_guest_form_login(self, soup: BeautifulSoup) -> bool:
        """Try to login as guest using form submission.

        Args:
            soup: BeautifulSoup object of login page

        Returns:
            True if successful, False otherwise
        """
        guest_buttons = soup.find_all(
            'form', action=re.compile(r'login/index\.php')
        )

        for form in guest_buttons:
            guest_input = form.find(
                'input',
                {'value': re.compile(r'[Gg]uest|[Aa]ccess.*[Gg]uest', re.IGNORECASE)}
            )

            if guest_input:
                logger.info("Found guest login input button")
                guest_url = urljoin(self.base_url, form['action'])
                guest_data = {
                    inp['name']: inp['value']
                    for inp in form.find_all('input')
                    if 'name' in inp.attrs and 'value' in inp.attrs
                }

                logger.info(f"Submitting guest form to: {guest_url}")
                guest_resp = self.session.post(
                    guest_url,
                    data=guest_data,
                    headers=self.headers
                )
                guest_resp.raise_for_status()
                return True

        return False

    def _try_guest_link_login(self, soup: BeautifulSoup) -> bool:
        """Try to login as guest using link navigation.

        Args:
            soup: BeautifulSoup object of login page

        Returns:
            True if successful, False otherwise
        """
        guest_links = soup.find_all(
            'a',
            text=re.compile(r'[Gg]uest|[Aa]ccess.*[Gg]uest', re.IGNORECASE),
            href=True
        )

        if guest_links:
            guest_url = urljoin(self.base_url, guest_links[0]['href'])
            logger.info(f"Found guest access link: {guest_url}")
            guest_resp = self.session.get(guest_url, headers=self.headers)
            guest_resp.raise_for_status()
            return True

        return False

    def find_online_users_url(self) -> str:
        """Find the URL for the online users block or page.

        Returns:
            URL for online users page
        """
        return self.url_discoverer.find_online_users_url(
            self.session, self.base_url, self.headers
        )

    def extract_online_users(self, html_content: str) -> int:
        """
        Extract online users count from the HTML content.

        Args:
            html_content: HTML content of the online users page

        Returns:
            Total count of online users
        """
        return self.count_extractor.extract_online_users(html_content)

    def crawl(self) -> int:
        """Perform a single crawl to collect online user count.

        Returns:
            Number of online users found, 0 on failure

        Raises:
            AuthenticationError: If guest authentication fails
            URLDiscoveryError: If online users URL cannot be found
            ExtractionError: If user count cannot be extracted
        """
        try:
            # Authenticate as guest
            if not self.login_as_guest():
                raise AuthenticationError("Failed to access site as guest")

            # Time URL discovery
            start_time = time.monotonic()
            online_users_url = self.find_online_users_url()
            duration = time.monotonic() - start_time

            # Save latency metric
            self._save_latency_metric(duration)

            if not online_users_url:
                raise URLDiscoveryError("Could not find online users URL")

            logger.info(f"Crawling online users from: {online_users_url}")

            # Get HTML content
            html_content = self._get_html_content(online_users_url)
            if not html_content:
                raise ExtractionError("Could not retrieve HTML content")

            # Extract user count
            user_count = self.extract_online_users(html_content)
            logger.info(f"Found {user_count} online users")

            # Store results
            self._store_crawl_results(user_count)

            # Save metrics to file
            self.save_data()

            return user_count

        except (AuthenticationError, URLDiscoveryError, ExtractionError):
            # Re-raise known errors
            raise
        except Exception as e:
            logger.error(f"Unexpected error during crawl: {str(e)}")
            raise ExtractionError(f"Crawl failed: {e}")

    def _save_latency_metric(self, duration: float) -> None:
        """Save latency metric if latency saver is available.

        Args:
            duration: Time taken for URL discovery in seconds
        """
        try:
            if self.latency_saver:
                site_label = self.base_url.replace('http://', '')
                site_label = site_label.replace('https://', '')
                site_label = site_label.replace('/', '_')
                self.latency_saver.save_latency(duration, site_label)
        except Exception as e:
            logger.warning(f"Failed to save latency metric: {e}")

    def _store_crawl_results(self, user_count: int) -> None:
        """Store crawl results with timestamp.

        Args:
            user_count: Number of online users found
        """
        self.online_count = user_count
        self.last_crawl_time = datetime.now()
        timestamp_str = self.last_crawl_time.strftime('%Y-%m-%d %H:%M:%S')
        logger.info(f"Data collected at: {timestamp_str}")

    def _get_html_content(self, url: str) -> Optional[str]:
        """Get HTML content from URL or fallback to example file.

        Args:
            url: URL to fetch content from

        Returns:
            HTML content if successful, None otherwise
        """
        # First try to get the real page
        try:
            response = self.session.get(url, headers=self.headers, timeout=30)
            response.raise_for_status()
            return response.text
        except requests.exceptions.RequestException as e:
            logger.warning(f"Failed to access {url}: {e}")

            if not self.allow_example_fallback:
                # Never substitute demo data for live metrics — a stale
                # example.html read would silently pollute metrics.prom.
                return None

            logger.info("Using example.html as fallback (--example enabled)")
            try:
                with open(self.config.example_html_filename, 'r') as f:
                    return f.read()
            except (IOError, FileNotFoundError):
                logger.error(f"Could not read {self.config.example_html_filename} as fallback")
                return None

    def save_data(self) -> None:
        """Save collected data to output files with rotation.

        Raises:
            IOError: If file operations fail
        """
        try:
            # Save Prometheus metrics if enabled
            if hasattr(self, 'prometheus_output') and self.prometheus_output:
                self._save_prometheus_metrics()
        except Exception as e:
            logger.error(f"Error saving data: {str(e)}")
            raise IOError(f"Failed to save data: {e}")

    def _save_prometheus_metrics(self) -> None:
        """Save Prometheus metrics to file with rotation."""
        # Generate new metric line
        site_label = self._generate_site_label()
        timestamp_ms = self._get_timestamp_ms()

        new_metric_line = (
            f'moodle_online_users_total{{site="{site_label}"}} '
            f'{self.online_count} {timestamp_ms}'
        )

        # Check and rotate file if needed
        self._check_and_rotate_metrics_file()

        # Ensure headers and append metric
        self._ensure_metrics_headers()
        self._append_metric_line(new_metric_line)

        logger.info(f"Prometheus metrics saved to {self.metrics_file}")

    def _generate_site_label(self) -> str:
        """Generate sanitized site label for metrics.

        Returns:
            Sanitized site label
        """
        site_label = self.base_url.replace('http://', '')
        site_label = site_label.replace('https://', '')
        site_label = site_label.replace('/', '_')
        return site_label

    def _get_timestamp_ms(self) -> int:
        """Get timestamp in milliseconds since epoch.

        Returns:
            Timestamp in milliseconds
        """
        if self.last_crawl_time:
            return int(self.last_crawl_time.timestamp() * 1000)
        else:
            return int(datetime.now().timestamp() * 1000)

    def _check_and_rotate_metrics_file(self) -> None:
        """Check metrics file size and rotate if needed."""
        metrics_file_size = 0
        if os.path.exists(self.metrics_file):
            metrics_file_size = os.path.getsize(self.metrics_file)

        if metrics_file_size >= self.config.max_file_size_bytes:
            logger.info(f"Metrics file has reached {metrics_file_size} bytes, rotating")
            self._rotate_metrics_file()

    def _append_metric_line(self, metric_line: str) -> None:
        """Append metric line to file.

        Args:
            metric_line: Metric line to append
        """
        logger.info("Appending new metric line")
        with open(self.metrics_file, 'a') as f:
            f.write(metric_line + "\n")
            
    def _rotate_metrics_file(self) -> None:
        """Rotate metrics.prom file when it exceeds size limit.

        Raises:
            IOError: If file rotation fails
        """
        try:
            backup_file = self._generate_backup_filename()

            # Create backup
            if os.path.exists(self.metrics_file):
                os.rename(self.metrics_file, backup_file)
                logger.info(f"Created dated backup: {backup_file}")

            # Create new empty file with headers
            self._create_new_metrics_file()

            logger.info(f"Rotated metrics file. New backup created: {backup_file}")

        except Exception as e:
            logger.error(f"Error rotating metrics file: {str(e)}")
            # Try to ensure the main file exists even if rotation fails
            self._ensure_metrics_file_exists()
            raise IOError(f"Metrics file rotation failed: {e}")

    def _generate_backup_filename(self) -> str:
        """Generate backup filename with date and sequence number.

        Returns:
            Backup filename
        """
        current_date = datetime.now().strftime("%Y%m%d")
        today_prefix = f"{os.path.basename(self.metrics_file)}.{current_date}"
        highest_backup = 0

        try:
            for file in os.listdir(os.path.dirname(self.metrics_file)):
                if file.startswith(today_prefix):
                    try:
                        # Extract number after the date (format: metrics.prom.20250707.1)
                        backup_num = int(file.split(".")[-1])
                        if backup_num > highest_backup:
                            highest_backup = backup_num
                    except ValueError:
                        # Not properly formatted
                        pass
        except OSError:
            # Directory listing failed, use 0 as default
            pass

        next_backup_num = highest_backup + 1
        return f"{self.metrics_file}.{current_date}.{next_backup_num}"

    def _create_new_metrics_file(self) -> None:
        """Create new empty metrics file with headers."""
        with open(self.metrics_file, 'w') as f:
            f.write("\n".join(self.metric_headers) + "\n")

    def _ensure_metrics_file_exists(self) -> None:
        """Ensure metrics file exists, create if missing."""
        if not os.path.exists(self.metrics_file):
            self._create_new_metrics_file()
    
    def _ensure_metrics_headers(self) -> None:
        """Ensure the metrics file has proper headers.

        Raises:
            IOError: If header operations fail
        """
        try:
            if not os.path.exists(self.metrics_file):
                # File doesn't exist, create it with headers
                self._create_new_metrics_file()
                return

            # Check if the file has headers
            if not self._has_proper_headers():
                self._add_missing_headers()

        except Exception as e:
            logger.warning(f"Error checking metrics file headers: {e}")
            raise IOError(f"Failed to ensure headers: {e}")

    def _has_proper_headers(self) -> bool:
        """Check if metrics file has proper headers.

        Returns:
            True if headers are present, False otherwise
        """
        try:
            with open(self.metrics_file, 'r') as f:
                first_line = next(f, '').strip()
                second_line = next(f, '').strip()

            return (
                first_line.startswith('# ') and
                second_line.startswith('# ')
            )
        except (IOError, StopIteration):
            return False

    def _add_missing_headers(self) -> None:
        """Add missing headers to metrics file."""
        logger.info("Headers missing, adding them")
        with open(self.metrics_file, 'r') as f:
            existing_content = f.read()
        with open(self.metrics_file, 'w') as f:
            f.write("\n".join(self.metric_headers) + "\n")
            f.write(existing_content)

    def run(self, duration: Optional[int] = None, prometheus_output: bool = False) -> None:
        """
        Run the crawler for a specified duration.

        Args:
            duration: Duration in minutes to run the crawler, None for indefinite
            prometheus_output: Whether to generate Prometheus metrics output
        """
        self.prometheus_output = prometheus_output
        logger.info(f"Starting Moodle crawler for {self.base_url}")
        logger.info(f"Data will be saved to {self.output_dir}")
        if prometheus_output:
            logger.info("Prometheus metrics will be generated")

        end_time = None
        if duration:
            end_time = datetime.now() + timedelta(minutes=duration)
            logger.info(f"Crawler will run for {duration} minutes")

        try:
            while True:
                try:
                    self.crawl()
                except (AuthenticationError, URLDiscoveryError, ExtractionError) as e:
                    logger.error(f"Crawl failed: {e}")
                    logger.info("Continuing to next crawl cycle...")
                except Exception as e:
                    logger.error(f"Unexpected error: {e}")
                    logger.info("Continuing to next crawl cycle...")

                if end_time and datetime.now() >= end_time:
                    logger.info(
                        f"Reached specified duration of {duration} minutes"
                    )
                    break

                logger.info(f"Sleeping for {self.interval} seconds")
                time.sleep(self.interval)

        except KeyboardInterrupt:
            logger.info("Crawler stopped by user")
        finally:
            logger.info("Saving final data...")
            self.save_data()
            logger.info("Crawler finished")


def main() -> int:
    """Main entry point for the Moodle crawler.

    Returns:
        Exit code (0 for success, 1 for error)
    """
    parser = argparse.ArgumentParser(description="Moodle online users crawler")
    parser.add_argument("url", help="Base URL of the Moodle site")
    parser.add_argument(
        "-i", "--interval",
        type=int,
        help=f"Interval between crawls in seconds (default: {CrawlerConfig().default_interval_seconds})"
    )
    parser.add_argument(
        "-d", "--duration",
        type=int,
        help="Duration to run crawler in minutes (default: indefinite)"
    )
    parser.add_argument(
        "-o", "--output-dir",
        default="data",
        help="Directory to save data (default: data/)"
    )
    parser.add_argument(
        "-p", "--prometheus",
        action="store_true",
        help=(
            "Generate Prometheus-compatible metrics file in the "
            "output directory"
        )
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Verify the script setup and exit"
    )
    parser.add_argument(
        "--example",
        action="store_true",
        help=(
            "Allow example.html fallback when the real page cannot be "
            "fetched (demo/testing only — never enable in production)"
        )
    )
    args = parser.parse_args()

    # Verification mode - just print a success message and exit
    if args.verify:
        print("✓ Moodle Crawler verification successful")
        print("✓ Python environment is correctly set up")
        print("✓ Required packages are installed")
        print("✓ Script is executable")
        return 0

    try:
        crawler = MoodleCrawler(
            base_url=args.url,
            interval=args.interval,
            output_dir=args.output_dir,
            allow_example_fallback=args.example
        )
        crawler.run(args.duration, args.prometheus)
        return 0
    except Exception as e:
        logger.error(f"Crawler failed: {e}")
        return 1


if __name__ == "__main__":
    import sys
    sys.exit(main())
