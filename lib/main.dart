import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';

const sourceUrl = 'https://www.ctee.com.tw/stock/twmarket';
const moneyDjSourceUrl =
    'https://www.moneydj.com/kmdj/news/newsreallist.aspx?a=mb07';
const backgroundTaskName = 'com.jordanyeh.tw_stock_news_ai_monitor.periodic';

const sourceCtee = 'ctee';
const sourceMoneyDj = 'moneydj';

String newsSourceIdForUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return host.contains('moneydj.com') ? sourceMoneyDj : sourceCtee;
}

String newsSourceLabelForUrl(String url) {
  return newsSourceIdForUrl(url) == sourceMoneyDj
      ? 'MoneyDJ 產業情報'
      : '工商時報';
}

bool isMoneyDjNewsUrl(String url) =>
    newsSourceIdForUrl(url) == sourceMoneyDj;

/// 工商時報是台灣媒體，新聞發布時間統一以 Asia/Taipei (UTC+8) 顯示。
///
/// Dart 在解析帶 +08:00 / +0800 的 ISO 字串時，會把 DateTime 正規化成 UTC。
/// 如果直接讀 year/month/hour，就可能把 16:19 顯示成 08:19。
///
/// 規則：
/// - 有 Z / +/-HH:mm 時區：先解析成真正時間點，再轉成固定 UTC+8。
/// - 沒有時區：視為工商時報頁面上的台灣本地時間，不再額外轉換。
DateTime? cteeTaipeiDateTime(String? value) {
  if (value == null || value.trim().isEmpty) return null;

  final raw = value.trim();
  final normalized = raw.replaceFirstMapped(
    RegExp(r'([+-]\d{2})(\d{2})$'),
    (m) => '${m.group(1)}:${m.group(2)}',
  );

  final parsed = DateTime.tryParse(normalized);
  if (parsed == null) return null;

  final hasExplicitTimezone = RegExp(
    r'(Z|[+-]\d{2}:?\d{2})$',
    caseSensitive: false,
  ).hasMatch(raw);

  if (hasExplicitTimezone) {
    // 固定顯示工商時報所在地時間，不依使用者 Windows / 手機時區。
    return parsed.toUtc().add(const Duration(hours: 8));
  }

  return parsed;
}

enum AiProvider { openai, gemini }

AiProvider aiProviderFromString(String? value) {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'gemini':
      return AiProvider.gemini;
    case 'openai':
    default:
      return AiProvider.openai;
  }
}

String aiProviderStorageValue(AiProvider provider) =>
    provider == AiProvider.gemini ? 'gemini' : 'openai';

String aiProviderLabel(AiProvider provider) =>
    provider == AiProvider.gemini ? 'Gemini' : 'OpenAI';

ThemeMode appThemeModeFromString(String? value) {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'dark':
      return ThemeMode.dark;
    case 'system':
      return ThemeMode.system;
    case 'light':
    default:
      return ThemeMode.light;
  }
}

String appThemeModeStorageValue(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.system:
      return 'system';
    case ThemeMode.light:
      return 'light';
  }
}

String appThemeModeLabel(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.dark:
      return '暗色';
    case ThemeMode.system:
      return '跟隨系統';
    case ThemeMode.light:
      return '明亮';
  }
}

/// App 全域外觀模式。設定頁修改後，MaterialApp 會立即重建。
final ValueNotifier<ThemeMode> appThemeMode =
    ValueNotifier<ThemeMode>(ThemeMode.light);

class NewsItem {
  NewsItem({
    required this.url,
    required this.title,
    required this.discoveredAt,
    this.publishedAt,
    this.author = '',
    this.tags = const [],
    this.metadataFetched = false,
    this.body = '',
    this.status = 'baseline',
    this.analysis,
    this.error,
  });

  final String url;
  String title;
  final String discoveredAt;
  String? publishedAt;
  String author;
  List<String> tags;
  bool metadataFetched;
  String body;
  String status;
  Map<String, dynamic>? analysis;
  String? error;

  factory NewsItem.fromJson(Map<String, dynamic> j) => NewsItem(
        url: j['url']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        discoveredAt:
            j['discovered_at']?.toString() ?? DateTime.now().toIso8601String(),
        publishedAt: j['published_at']?.toString(),
        author: j['author']?.toString() ?? '',
        tags: j['tags'] is List
            ? (j['tags'] as List).map((e) => e.toString()).toList()
            : <String>[],
        metadataFetched: j['metadata_fetched'] == true,
        body: j['body']?.toString() ?? '',
        status: j['status']?.toString() ?? 'baseline',
        analysis: j['analysis'] is Map
            ? (j['analysis'] as Map).cast<String, dynamic>()
            : null,
        error: j['error']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'discovered_at': discoveredAt,
        'published_at': publishedAt,
        'author': author,
        'tags': tags,
        'metadata_fetched': metadataFetched,
        'body': body,
        'status': status,
        'analysis': analysis,
        'error': error,
      };
}

class ListingItem {
  const ListingItem(this.url, this.title, this.publishedAt);
  final String url;
  final String title;
  final String? publishedAt;
}


class Store {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  // 同一個 isolate 內，單篇新聞更新必須依序寫入。
  // 這可以避免兩個「重新分析」幾乎同時完成時互相覆蓋 history。
  static Future<void> _newsMutationQueue = Future<void>.value();

  Future<T> _withNewsMutationLock<T>(
    Future<T> Function() action,
  ) {
    final completer = Completer<T>();

    _newsMutationQueue = _newsMutationQueue.then((_) async {
      try {
        final result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    return completer.future;
  }

  static const _history = 'history_v1';
  static const _initialized = 'initialized_v1';
  static const _moneyDjInitialized = 'initialized_moneydj_v1';
  static const _provider = 'ai_provider';
  static const _openAiApiKey = 'openai_api_key';
  static const _openAiModel = 'openai_model';
  static const _geminiApiKey = 'gemini_api_key';
  static const _geminiModel = 'gemini_model';
  static const _enabled = 'monitor_enabled';
  static const _cteeEnabled = 'source_ctee_enabled';
  static const _moneyDjEnabled = 'source_moneydj_enabled';
  static const _themeMode = 'theme_mode';

  // 清除新聞資料相關的內部狀態。
  static const _ignoredNewsUrls = 'ignored_news_urls_v1';
  static const _clearCutoffCtee = 'clear_cutoff_ctee_v1';
  static const _clearCutoffMoneyDj = 'clear_cutoff_moneydj_v1';

  Future<List<NewsItem>> load() async {
    final raw = await _prefs.getString(_history);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => NewsItem.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<NewsItem> items) async {
    await _prefs.setString(
      _history,
      jsonEncode(items.take(400).map((e) => e.toJson()).toList()),
    );
  }

  /// 只更新指定 URL 的單篇新聞。
  ///
  /// 重新分析可能同時進行多篇；若每個工作都把自己先前 load() 的整份
  /// history save() 回去，較晚完成的工作會用舊快照蓋掉較早完成的結果。
  ///
  /// 這裡每次都在真正寫入前重新讀取最新 history，且只替換指定 URL，
  /// 因此 A/B 兩篇同時分析也不會互相覆蓋。
  Future<void> updateNewsItem(NewsItem updatedItem) {
    return _withNewsMutationLock<void>(() async {
      final latest = await load();
      final index = latest.indexWhere(
        (e) => e.url == updatedItem.url,
      );

      if (index < 0) {
        throw Exception('找不到要更新的新聞：${updatedItem.url}');
      }

      // 建立獨立 copy，避免呼叫端之後繼續 mutate 同一個 reference。
      latest[index] = NewsItem.fromJson(updatedItem.toJson());

      await _prefs.setString(
        _history,
        jsonEncode(
          latest.take(400).map((e) => e.toJson()).toList(),
        ),
      );
    });
  }

  Future<bool> initialized() async =>
      (await _prefs.getBool(_initialized)) ?? false;

  Future<void> setInitialized() => _prefs.setBool(_initialized, true);

  Future<bool> initializedFor(String sourceId) async {
    if (sourceId == sourceMoneyDj) {
      return (await _prefs.getBool(_moneyDjInitialized)) ?? false;
    }
    return initialized();
  }

  Future<void> setInitializedFor(String sourceId) {
    if (sourceId == sourceMoneyDj) {
      return _prefs.setBool(_moneyDjInitialized, true);
    }
    return setInitialized();
  }

  Future<AiProvider> provider() async =>
      aiProviderFromString(await _prefs.getString(_provider));

  Future<void> setProvider(AiProvider value) =>
      _prefs.setString(_provider, aiProviderStorageValue(value));

  Future<String> openAiApiKey() async =>
      (await _secure.read(key: _openAiApiKey)) ?? '';

  Future<void> setOpenAiApiKey(String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await _secure.delete(key: _openAiApiKey);
    } else {
      await _secure.write(key: _openAiApiKey, value: v);
    }
  }

  Future<String> openAiModel() async =>
      (await _prefs.getString(_openAiModel)) ?? 'gpt-5.4-mini';

  Future<void> setOpenAiModel(String value) => _prefs.setString(
        _openAiModel,
        value.trim().isEmpty ? 'gpt-5.4-mini' : value.trim(),
      );

  Future<String> geminiApiKey() async =>
      (await _secure.read(key: _geminiApiKey)) ?? '';

  Future<void> setGeminiApiKey(String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await _secure.delete(key: _geminiApiKey);
    } else {
      await _secure.write(key: _geminiApiKey, value: v);
    }
  }

  Future<String> geminiModel() async {
    final saved = (await _prefs.getString(_geminiModel))?.trim();

    // Gemini 2.5 Flash-Lite is no longer available to new API users.
    // Automatically migrate the old v7 default to the current Flash-Lite model.
    if (saved == null ||
        saved.isEmpty ||
        saved == 'gemini-2.5-flash-lite') {
      const migrated = 'gemini-3.5-flash-lite';
      await _prefs.setString(_geminiModel, migrated);
      return migrated;
    }

    return saved;
  }

  Future<void> setGeminiModel(String value) => _prefs.setString(
        _geminiModel,
        value.trim().isEmpty ? 'gemini-3.5-flash-lite' : value.trim(),
      );

  Future<String> apiKey() async {
    final p = await provider();
    return p == AiProvider.gemini ? geminiApiKey() : openAiApiKey();
  }

  Future<String> model() async {
    final p = await provider();
    return p == AiProvider.gemini ? geminiModel() : openAiModel();
  }

  Future<bool> enabled() async =>
      (await _prefs.getBool(_enabled)) ?? true;

  Future<void> setEnabled(bool v) => _prefs.setBool(_enabled, v);

  Future<bool> cteeEnabled() async =>
      (await _prefs.getBool(_cteeEnabled)) ?? true;

  Future<void> setCteeEnabled(bool v) =>
      _prefs.setBool(_cteeEnabled, v);

  Future<bool> moneyDjEnabled() async =>
      (await _prefs.getBool(_moneyDjEnabled)) ?? true;

  Future<void> setMoneyDjEnabled(bool v) =>
      _prefs.setBool(_moneyDjEnabled, v);

  Future<ThemeMode> themeMode() async =>
      appThemeModeFromString(await _prefs.getString(_themeMode));

  Future<void> setThemeMode(ThemeMode mode) =>
      _prefs.setString(_themeMode, appThemeModeStorageValue(mode));

  Future<Set<String>> ignoredNewsUrls() async {
    final raw = await _prefs.getString(_ignoredNewsUrls);
    if (raw == null || raw.trim().isEmpty) return <String>{};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};

      return decoded
          .whereType<String>()
          .where((e) => e.trim().isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _saveIgnoredNewsUrls(Set<String> urls) async {
    final list = urls.toList();

    // 最多保留 2000 個 URL，避免 SharedPreferences 無限制成長。
    final capped = list.length > 2000
        ? list.sublist(list.length - 2000)
        : list;

    await _prefs.setString(
      _ignoredNewsUrls,
      jsonEncode(capped),
    );
  }

  Future<DateTime?> clearCutoffFor(String sourceId) async {
    final key = sourceId == sourceMoneyDj
        ? _clearCutoffMoneyDj
        : _clearCutoffCtee;

    final raw = await _prefs.getString(key);
    final milliseconds = int.tryParse(raw ?? '');
    if (milliseconds == null) return null;

    // 這裡只拿來與 cteeTaipeiDateTime() 的結果比較時間先後。
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
      isUtc: true,
    );
  }

  Future<void> _setClearCutoff(
    String sourceId,
    DateTime time,
  ) async {
    final key = sourceId == sourceMoneyDj
        ? _clearCutoffMoneyDj
        : _clearCutoffCtee;

    await _prefs.setString(
      key,
      time.millisecondsSinceEpoch.toString(),
    );
  }

  /// 清除使用者看得到的新聞、正文與 AI 分析。
  ///
  /// 不會刪除：
  /// - OpenAI / Gemini API Key
  /// - Model
  /// - 監控與新聞來源開關
  /// - 外觀設定
  ///
  /// 清除後不保留先前新聞狀態，下一次檢查會重新建立來源基準。
  
  Future<int> clearFetchedNews() async {
    final items = await load();
    final count = items.length;

    // 完整清除所有「已抓取新聞」相關狀態。
    //
    // 不保留：
    // - 新聞歷史
    // - 隱藏去重 URL
    // - 各來源 clear cutoff
    // - 各來源 baseline / initialized 狀態
    //
    // 下一次檢查會視同第一次啟用來源，重新以網站當下內容建立 baseline。
    await _prefs.remove(_history);
    await _prefs.remove(_ignoredNewsUrls);
    await _prefs.remove(_clearCutoffCtee);
    await _prefs.remove(_clearCutoffMoneyDj);
    await _prefs.remove(_initialized);
    await _prefs.remove(_moneyDjInitialized);

    return count;
  }
}


class Scraper {
  /// 不把工商時報文章 URL 格式綁死。
  /// 只要是 /news/... 且路徑中含至少 6 位數文章 ID，就列為文章候選。
  bool _isArticlePath(String path) {
    if (!path.startsWith('/news/')) return false;
    final tail = path.substring('/news/'.length);
    if (tail.isEmpty) return false;
    return RegExp(r'\d{6,}').hasMatch(tail);
  }

  Map<String, String> get headers => const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152 Safari/537.36',
        'Accept-Language': 'zh-TW,zh;q=0.9',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.ctee.com.tw/',
        'Cache-Control': 'no-cache, no-store, max-age=0',
        'Pragma': 'no-cache',
      };

  Future<List<ListingItem>> listing() async {
    final base = Uri.parse(sourceUrl);

    // 每次檢查都加唯一 query，盡量避開 CDN / proxy 的舊分類頁快取。
    final requestUri = base.replace(
      queryParameters: {
        ...base.queryParameters,
        '_ctee_monitor_ts':
            DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );

    final r = await http
        .get(requestUri, headers: headers)
        .timeout(const Duration(seconds: 20));

    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('工商時報 HTTP ${r.statusCode}');
    }

    final htmlText = utf8.decode(r.bodyBytes);
    final doc = html_parser.parse(htmlText);
    final result = <ListingItem>[];
    final seen = <String>{};

    String canonicalUrl(Uri uri) {
      var path = uri.path;
      if (path.length > 1 && path.endsWith('/')) {
        path = path.substring(0, path.length - 1);
      }

      return uri.replace(
        path: path,
        query: '',
        fragment: '',
      ).toString();
    }

    void addCandidate(
      String rawUrl, {
      String title = '',
      String? time,
    }) {
      if (rawUrl.trim().isEmpty) return;

      Uri uri;
      try {
        uri = base.resolve(rawUrl.trim());
      } catch (_) {
        return;
      }

      if (!uri.host.endsWith('ctee.com.tw')) return;
      if (!_isArticlePath(uri.path)) return;

      final url = canonicalUrl(uri);
      if (!seen.add(url)) return;

      final cleanTitle = clean(title);
      result.add(
        ListingItem(
          url,
          cleanTitle.length >= 4 ? cleanTitle : '（由新聞內頁讀取標題）',
          (time == null || time.trim().isEmpty) ? null : time,
        ),
      );
    }

    // 1. 先讀一般 DOM anchor。
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';

      var title = clean(a.text);
      if (title.length < 4) title = clean(a.attributes['title'] ?? '');
      if (title.length < 4) {
        title = clean(a.querySelector('img')?.attributes['alt'] ?? '');
      }

      addCandidate(
        href,
        title: title,
        time: nearbyTime(a.parent?.text ?? a.text),
      );
    }

    // 2. 再掃原始 HTML / hydration JSON。
    // 現代網站可能由 JavaScript 把最新新聞畫到瀏覽器，
    // 直接 HTTP 抓到的 DOM 未必已有那些 <a>。
    final normalizedHtml = htmlText
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u002F', '/')
        .replaceAll('&amp;', '&');

    final rawUrlRe = RegExp(
      r'(/news/[A-Za-z0-9_./-]*\d{6,}[A-Za-z0-9_./-]*)',
      caseSensitive: false,
    );

    for (final m in rawUrlRe.allMatches(normalizedHtml)) {
      final path = m.group(1);
      if (path != null) addCandidate(path);
    }

    // 網站可能插入很多置頂 / 推薦區塊，因此提高上限，不再只看前 40 篇。
    return result.length > 150 ? result.take(150).toList() : result;
  }

  Future<NewsItem> detail(ListingItem item) async {
    final r = await http
        .get(Uri.parse(item.url), headers: headers)
        .timeout(const Duration(seconds: 20));

    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('新聞頁 HTTP ${r.statusCode}');
    }

    final doc = html_parser.parse(utf8.decode(r.bodyBytes));
    String title = item.title;

    // 發布時間一定優先從「新聞內頁」取得。
    // 列表頁時間只能在文章頁完全抓不到時間時，才作為最後 fallback。
    String? publishedAt;
    String author = '';
    final tags = <String>[];
    String body = '';

    for (final script
        in doc.querySelectorAll('script[type="application/ld+json"]')) {
      final raw = script.text.trim();
      if (raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        for (final obj in jsonObjects(decoded)) {
          final t = obj['@type'];
          final types =
              t is List ? t.map((e) => e.toString()).toList() : [t?.toString()];
          if (!types.any((x) =>
              x == 'NewsArticle' ||
              x == 'Article' ||
              x == 'ReportageNewsArticle')) {
            continue;
          }
          final h = obj['headline']?.toString() ?? obj['name']?.toString();
          if (h != null && h.trim().isNotEmpty) title = clean(h);
          publishedAt ??= obj['datePublished']?.toString();

          // 作者：JSON-LD 的 author 可能是 Person、陣列或純字串。
          if (author.isEmpty && obj['author'] != null) {
            author = extractAuthor(obj['author']);
          }

          // 標籤：schema.org NewsArticle 常放在 keywords。
          addTags(tags, obj['keywords']);

          final b = obj['articleBody']?.toString() ?? '';
          if (b.length > body.length) body = b.trim();
        }
      } catch (_) {}
    }

    final ogTitle =
        doc.querySelector('meta[property="og:title"]')?.attributes['content'];
    if (title.isEmpty && ogTitle != null) title = clean(ogTitle);
    // 新聞頁發布時間 fallback 順序：
    // 1. JSON-LD datePublished（上面已先讀）
    // 2. OpenGraph article:published_time
    // 3. schema.org itemprop=datePublished
    // 4. 常見 pubdate/date meta
    // 5. <time datetime>
    // 6. 從新聞頁可見文字尋找 yyyy/mm/dd HH:mm
    // 7. 最後才退回列表頁時間
    publishedAt ??= doc
        .querySelector('meta[property="article:published_time"]')
        ?.attributes['content'];
    publishedAt ??= doc
        .querySelector('meta[itemprop="datePublished"]')
        ?.attributes['content'];
    publishedAt ??=
        doc.querySelector('meta[name="pubdate"]')?.attributes['content'];
    publishedAt ??=
        doc.querySelector('meta[name="date"]')?.attributes['content'];
    publishedAt ??= doc.querySelector('time[datetime]')?.attributes['datetime'];

    if (publishedAt == null || publishedAt!.trim().isEmpty) {
      publishedAt = pagePublishedTime(
          doc.body?.text ?? doc.documentElement?.text ?? '',
        );
    }

    if (publishedAt == null || publishedAt!.trim().isEmpty) {
      publishedAt = item.publishedAt;
    }

    // 作者 fallback：meta -> 常見作者/記者區塊。
    if (author.isEmpty) {
      for (final selector in const [
        'meta[name="author"]',
        'meta[property="article:author"]',
        'meta[name="parsely-author"]',
      ]) {
        final value = doc.querySelector(selector)?.attributes['content'];
        if (value != null && value.trim().isNotEmpty) {
          author = normalizeAuthor(value);
          if (author.isNotEmpty) break;
        }
      }
    }

    if (author.isEmpty) {
      for (final selector in const [
        '.author',
        '.article-author',
        '.news-author',
        '.byline',
        '.writer',
        '[class*="author"]',
      ]) {
        final value = doc.querySelector(selector)?.text;
        if (value != null && value.trim().isNotEmpty) {
          author = normalizeAuthor(value);
          if (author.isNotEmpty) break;
        }
      }
    }

    // 標籤 fallback：article:tag / keywords / 頁面上的 #hashtag 連結。
    for (final meta in doc.querySelectorAll('meta[property="article:tag"]')) {
      addTags(tags, meta.attributes['content']);
    }
    addTags(tags, doc.querySelector('meta[name="keywords"]')?.attributes['content']);
    addTags(tags, doc.querySelector('meta[name="news_keywords"]')?.attributes['content']);

    for (final a in doc.querySelectorAll('a')) {
      final txt = clean(a.text);
      if (txt.startsWith('#') && txt.length > 1 && txt.length <= 30) {
        addTag(tags, txt);
      }
    }

    if (body.length < 100) {
      String best = '';
      for (final selector in const [
        '[itemprop="articleBody"]',
        '.article-body',
        '.article-content',
        '.news-content',
        '.entry-content',
        '.story-content',
        'article'
      ]) {
        for (final node in doc.querySelectorAll(selector)) {
          final text = node
              .querySelectorAll('p, h2, h3, li')
              .map((e) => clean(e.text))
              .where((e) => e.length >= 8)
              .join('\n');
          if (text.length > best.length) best = text;
        }
      }
      body = best;
    }

    if (body.length < 100) {
      body = doc
          .querySelectorAll('p')
          .map((e) => clean(e.text))
          .where((e) => e.length >= 12)
          .join('\n');
    }

    return NewsItem(
      url: item.url,
      title: title,
      publishedAt: publishedAt,
      author: author,
      tags: tags.take(12).toList(),
      metadataFetched: true,
      discoveredAt: DateTime.now().toIso8601String(),
      body: body,
      status: 'analyzing',
    );
  }

  Iterable<Map<String, dynamic>> jsonObjects(dynamic v) sync* {
    if (v is Map) {
      final m = v.cast<String, dynamic>();
      yield m;
      for (final child in m.values) {
        yield* jsonObjects(child);
      }
    } else if (v is List) {
      for (final child in v) {
        yield* jsonObjects(child);
      }
    }
  }

  String nearbyTime(String text) {
    final m = RegExp(
      r'(20\d{2})[./-](\d{1,2})[./-](\d{1,2})\s+(\d{1,2}):(\d{2})',
    ).firstMatch(text);
    if (m == null) return '';
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
    ).toIso8601String();
  }

  String? pagePublishedTime(String text) {
    // 例如：
    // 2026/09/10 15:32
    // 2026-09-10 15:32
    // 2026.09.10 15:32:18
    final m = RegExp(
      r'(20\d{2})[./-](\d{1,2})[./-](\d{1,2})'
      r'(?:\s+|T)(\d{1,2}):(\d{2})(?::(\d{2}))?',
    ).firstMatch(text);

    if (m == null) return null;

    final dt = DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6) ?? '0'),
    );
    return dt.toIso8601String();
  }

  String extractAuthor(dynamic value) {
    final names = <String>[];

    void collect(dynamic v) {
      if (v == null) return;
      if (v is String) {
        final n = normalizeAuthor(v);
        if (n.isNotEmpty) names.add(n);
      } else if (v is Map) {
        final name = v['name']?.toString();
        if (name != null) {
          final n = normalizeAuthor(name);
          if (n.isNotEmpty) names.add(n);
        }
      } else if (v is List) {
        for (final x in v) {
          collect(x);
        }
      }
    }

    collect(value);
    return names.toSet().where((e) => e != '工商時報').join('、');
  }

  String normalizeAuthor(String value) {
    var v = clean(value);
    v = v.replaceFirst(
      RegExp(r'^(?:作者|記者|撰文|文)[：:\s／/]*'),
      '',
    );
    v = v.replaceFirst(
      RegExp(r'^工商時報[\s／/｜|・·-]*'),
      '',
    );
    v = v.replaceFirst(RegExp(r'[\s　]*(?:報導|採訪)$'), '');
    return clean(v);
  }

  void addTags(List<String> tags, dynamic value) {
    if (value == null) return;
    if (value is List) {
      for (final x in value) {
        addTags(tags, x);
      }
      return;
    }

    for (final raw in value.toString().split(RegExp(r'[,，;；、|｜]'))) {
      addTag(tags, raw);
    }
  }

  void addTag(List<String> tags, String value) {
    var tag = clean(value);
    tag = tag.replaceFirst(RegExp(r'^#+'), '');
    if (tag.isEmpty || tag.length > 30) return;
    if (!tags.contains(tag)) tags.add(tag);
  }

  String clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}


class MoneyDjScraper {
  Map<String, String> get headers => const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152 Safari/537.36',
        'Accept-Language': 'zh-TW,zh;q=0.9',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.moneydj.com/',
        'Cache-Control': 'no-cache, no-store, max-age=0',
        'Pragma': 'no-cache',
      };

  Future<List<ListingItem>> listing() async {
    final base = Uri.parse(moneyDjSourceUrl);
    final requestUri = base.replace(
      queryParameters: {
        ...base.queryParameters,
        '_monitor_ts': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );

    final r = await http
        .get(requestUri, headers: headers)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('MoneyDJ HTTP ${r.statusCode}');
    }

    final doc = html_parser.parse(utf8.decode(r.bodyBytes));
    final result = <ListingItem>[];
    final seen = <String>{};

    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href']?.trim() ?? '';
      if (href.isEmpty) continue;

      Uri uri;
      try {
        uri = base.resolve(href);
      } catch (_) {
        continue;
      }

      if (!uri.host.toLowerCase().contains('moneydj.com')) continue;
      if (!uri.path.toLowerCase().endsWith('/news/newsviewer.aspx')) continue;

      String? articleId;
      String? category;
      for (final entry in uri.queryParameters.entries) {
        final key = entry.key.toLowerCase();
        if (key == 'a') articleId = entry.value.trim();
        if (key == 'c') category = entry.value.trim();
      }

      if (articleId == null || articleId!.isEmpty) continue;
      if (category != null &&
          category!.isNotEmpty &&
          category!.toLowerCase() != 'mb07') {
        continue;
      }

      final title = _clean(a.text);
      if (title.length < 4) continue;

      final canonical = Uri(
        scheme: 'https',
        host: 'www.moneydj.com',
        path: '/kmdj/news/newsviewer.aspx',
        queryParameters: {'a': articleId!, 'c': 'MB07'},
      ).toString();
      if (!seen.add(canonical)) continue;

      final nearby = <String>[
        a.text,
        a.parent?.text ?? '',
        a.parent?.parent?.text ?? '',
        a.parent?.parent?.parent?.text ?? '',
      ].join(' ');

      result.add(ListingItem(canonical, title, _listPublishedTime(nearby)));
    }

    return result.length > 100 ? result.take(100).toList() : result;
  }

  Future<NewsItem> detail(ListingItem item) async {
    final r = await http
        .get(Uri.parse(item.url), headers: headers)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('MoneyDJ 新聞頁 HTTP ${r.statusCode}');
    }

    final doc = html_parser.parse(utf8.decode(r.bodyBytes));
    final fullText = doc.body?.text ?? doc.documentElement?.text ?? '';

    var title = _clean(doc.querySelector('h1')?.text ?? '');
    if (title.isEmpty) {
      title = _clean(
        doc.querySelector('meta[property="og:title"]')?.attributes['content'] ??
            item.title,
      );
      title = title.replaceFirst(
        RegExp(r'\s*[-–｜|]\s*MoneyDJ理財網\s*$'),
        '',
      );
    }

    String? publishedAt = _pagePublishedTime(fullText);
    publishedAt ??= doc
        .querySelector('meta[property="article:published_time"]')
        ?.attributes['content'];
    publishedAt ??=
        doc.querySelector('meta[itemprop="datePublished"]')?.attributes['content'];
    publishedAt ??= doc.querySelector('time[datetime]')?.attributes['datetime'];
    publishedAt ??= item.publishedAt;

    var author = _clean(
      doc.querySelector('meta[name="author"]')?.attributes['content'] ?? '',
    );

    // MoneyDJ 最常見署名格式：
    // MoneyDJ新聞 2026-09-10 10:54:39 張以忠 發佈
    // MoneyDJ新聞 2026-09-10 12:44:28 新聞中心 發佈
    // MoneyDJ新聞 2026-09-10 11:49:06 新聞編譯 發佈
    // MoneyDJ新聞 2026-09-10 09:28:57 數位內容中心 發佈
    if (author.isEmpty) {
      final normalizedText = _clean(fullText);
      final moneyDjAuthorMatch = RegExp(
        r'MoneyDJ新聞\s+'
        r'20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}\s+'
        r'\d{1,2}:\d{2}(?::\d{2})?\s+'
        r'(.{1,40}?)\s+發佈',
        caseSensitive: false,
      ).firstMatch(normalizedText);

      if (moneyDjAuthorMatch != null) {
        author = _clean(moneyDjAuthorMatch.group(1) ?? '');
      }
    }

    // 另一種常見新聞稿格式。
    if (author.isEmpty) {
      final m = RegExp(
        r'記者\s*([^\s／/]{2,20})\s*(?:報導|撰文)',
      ).firstMatch(fullText);
      if (m != null) author = _clean(m.group(1) ?? '');
    }

    // 公開資訊觀測站重大訊息沒有 MoneyDJ 記者署名時，
    // 顯示實際資訊來源，避免 UI 完全空白。
    if (author.isEmpty &&
        fullText.contains('公開資訊觀測站重大訊息公告')) {
      author = '公開資訊觀測站';
    }

    final lines = fullText
        .split(RegExp(r'[\r\n]+'))
        .map(_clean)
        .where((e) => e.isNotEmpty)
        .toList();

    final tags = <String>[];
    for (final line in lines) {
      if (!line.startsWith('分類主題：') && !line.startsWith('分類主題:')) {
        continue;
      }
      final raw = line.replaceFirst(RegExp(r'^分類主題[:：]\s*'), '').trim();
      for (final part in raw.split(RegExp(r'[‧・·｜|、]+'))) {
        final tag = _clean(part);
        if (tag.isEmpty || tag.length > 30) continue;
        if (!tags.contains(tag)) tags.add(tag);
        if (tags.length >= 12) break;
      }
      break;
    }

    String body = '';
    if (lines.isNotEmpty) {
      var startIndex = lines.indexWhere((line) => title.isNotEmpty && line.contains(title));
      if (startIndex < 0) startIndex = 0;
      startIndex = startIndex + 1;
      if (startIndex > lines.length) startIndex = lines.length;

      var endIndex = lines.indexWhere(
        (line) => line == '推薦新聞' || line.startsWith('分類主題：'),
        startIndex,
      );
      if (endIndex < 0) endIndex = lines.length;

      body = lines.sublist(startIndex, endIndex).where((line) {
        if (RegExp(r'^人氣\(\d+\)\s+20\d{2}/\d{1,2}/\d{1,2}')
            .hasMatch(line)) return false;
        if (line == '字級設定： 小 中 大 特') return false;
        return true;
      }).join('\n').trim();
    }

    if (body.length < 50) {
      body = doc
          .querySelectorAll('p')
          .map((e) => _clean(e.text))
          .where((e) => e.length >= 8)
          .join('\n');
    }
    if (body.length > 16000) body = body.substring(0, 16000);

    return NewsItem(
      url: item.url,
      title: title.isEmpty ? item.title : title,
      publishedAt: publishedAt,
      author: author,
      tags: tags,
      metadataFetched: true,
      body: body,
      discoveredAt: DateTime.now().toIso8601String(),
      status: 'new',
    );
  }

  String? _listPublishedTime(String text) {
    final m = RegExp(r'(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})')
        .firstMatch(text);
    if (m == null) return null;

    final nowTaipei = DateTime.now().toUtc().add(const Duration(hours: 8));
    var result = DateTime(
      nowTaipei.year,
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
    );

    if (result.isAfter(nowTaipei.add(const Duration(days: 2)))) {
      result = DateTime(
        nowTaipei.year - 1,
        result.month,
        result.day,
        result.hour,
        result.minute,
      );
    }
    return result.toIso8601String();
  }

  String? _pagePublishedTime(String text) {
    final m = RegExp(
      r'(20\d{2})[./-](\d{1,2})[./-](\d{1,2})'
      r'(?:\s+|T)(\d{1,2}):(\d{2})(?::(\d{2}))?',
    ).firstMatch(text);
    if (m == null) return null;

    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6) ?? '0'),
    ).toIso8601String();
  }

  String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class OpenAIAnalyzer {
  Future<Map<String, dynamic>> analyze({
    required String apiKey,
    required String model,
    required NewsItem item,
  }) async {
    if (apiKey.isEmpty) throw Exception('尚未設定 OpenAI API Key');
    if (item.body.length < 50) throw Exception('新聞正文擷取不足');

    final schema = {
      'type': 'object',
      'properties': {
        'sentiment': {
          'type': 'string',
          'enum': ['利多', '偏多', '中性', '偏空', '利空']
        },
        'sentiment_score': {'type': 'integer', 'minimum': -2, 'maximum': 2},
        'time_horizon': {
          'type': 'array',
          'items': {'type': 'string', 'enum': ['短線', '中期', '長期']}
        },
        'core_conclusion': {'type': 'string'},
        'event_types': {'type': 'array', 'items': {'type': 'string'}},
        'key_points': {'type': 'array', 'items': {'type': 'string'}},
        'transfer_order': {
          'type': 'object',
          'properties': {
            'is_transfer_order': {'type': 'boolean'},
            'evidence': {'type': 'string'},
            'beneficiaries': {'type': 'array', 'items': {'type': 'string'}}
          },
          'required': ['is_transfer_order', 'evidence', 'beneficiaries'],
          'additionalProperties': false
        },
        'scarcity': {
          'type': 'object',
          'properties': {
            'is_scarcity_theme': {'type': 'boolean'},
            'scarce_item': {'type': 'string'},
            'why_scarce': {'type': 'string'},
            'duration': {'type': 'string'},
            'beneficiaries': {'type': 'array', 'items': {'type': 'string'}}
          },
          'required': [
            'is_scarcity_theme',
            'scarce_item',
            'why_scarce',
            'duration',
            'beneficiaries'
          ],
          'additionalProperties': false
        },
        'affected_companies': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'company': {'type': 'string'},
              'ticker': {'type': 'string'},
              'direction': {'type': 'string'},
              'reason': {'type': 'string'},
              'confidence': {'type': 'integer', 'minimum': 0, 'maximum': 100}
            },
            'required': [
              'company',
              'ticker',
              'direction',
              'reason',
              'confidence'
            ],
            'additionalProperties': false
          }
        },
        'beneficiary_industries': {
          'type': 'array',
          'items': {'type': 'string'}
        },
        'negative_industries': {
          'type': 'array',
          'items': {'type': 'string'}
        },
        'catalysts': {'type': 'array', 'items': {'type': 'string'}},
        'risks': {'type': 'array', 'items': {'type': 'string'}},
        'watch_items': {'type': 'array', 'items': {'type': 'string'}},
        'confidence': {'type': 'integer', 'minimum': 0, 'maximum': 100}
      },
      'required': [
        'sentiment',
        'sentiment_score',
        'time_horizon',
        'core_conclusion',
        'event_types',
        'key_points',
        'transfer_order',
        'scarcity',
        'affected_companies',
        'beneficiary_industries',
        'negative_industries',
        'catalysts',
        'risks',
        'watch_items',
        'confidence'
      ],
      'additionalProperties': false
    };

    const instructions = """
你是台股事件驅動研究員。根據新聞本身分析可能的台股影響，不喊單、不提供目標價。
使用繁體中文，嚴格區分新聞事實與推論。
「轉單」必須有原供應商受阻、客戶改單、產能替代或供應鏈重分配證據；需求增加不等於轉單。
若判斷不是轉單，transfer_order.is_transfer_order 必須為 false，且 transfer_order.beneficiaries 必須回傳空陣列 []。
「稀缺題材」要指出稀缺的是什麼、原因、可能持續時間與潛在受惠者。
檢查財報、營收、訂單、漲價、政策、產能、供應鏈、匯率、利率、原物料與產業趨勢。
股票代號不確定就留空字串，不可猜。
一次性消息不要誇大成長期趨勢。
""";

    final bodyText =
        item.body.substring(0, item.body.length > 16000 ? 16000 : item.body.length);

    final r = await http
        .post(
          Uri.parse('https://api.openai.com/v1/responses'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({
            'model': model,
            'store': false,
            'reasoning': {'effort': 'low'},
            'instructions': instructions,
            'input':
                '新聞來源：${newsSourceLabelForUrl(item.url)}\n'
                '新聞標題：${item.title}\n發布時間：${item.publishedAt ?? '未知'}\n'
                '原文：${item.url}\n\n新聞正文：\n$bodyText',
            'text': {
              'format': {
                'type': 'json_schema',
                'name': 'ctee_stock_news_analysis',
                'strict': true,
                'schema': schema
              }
            }
          }),
        )
        .timeout(const Duration(seconds: 90));

    final raw = utf8.decode(r.bodyBytes);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception(_apiErrorMessage(r.statusCode, raw));
    }

    final payload = jsonDecode(raw) as Map<String, dynamic>;
    String output = payload['output_text']?.toString() ?? '';

    if (output.isEmpty && payload['output'] is List) {
      for (final item in payload['output'] as List) {
        if (item is! Map || item['content'] is! List) continue;
        for (final c in item['content'] as List) {
          if (c is Map && c['type'] == 'output_text') {
            output += c['text']?.toString() ?? '';
          }
        }
      }
    }

    if (output.isEmpty) throw Exception('OpenAI 回傳空分析');
    return (jsonDecode(output) as Map).cast<String, dynamic>();
  }

  Future<String> testConnection({
    required String apiKey,
    required String model,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('尚未設定 OpenAI API Key');
    }

    final r = await http
        .post(
          Uri.parse('https://api.openai.com/v1/responses'),
          headers: {
            'Authorization': 'Bearer ${apiKey.trim()}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model.trim(),
            'store': false,
            'input': '請只回覆 OK',
            'max_output_tokens': 64,
          }),
        )
        .timeout(const Duration(seconds: 45));

    final raw = utf8.decode(r.bodyBytes);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception(_apiErrorMessage(r.statusCode, raw));
    }

    return '連線成功：${model.trim()} 可使用 Responses API';
  }

  String _apiErrorMessage(int statusCode, String raw) {
    try {
      final payload = jsonDecode(raw);
      if (payload is Map && payload['error'] is Map) {
        final error = payload['error'] as Map;
        final message = error['message']?.toString();
        final type = error['type']?.toString();
        final code = error['code']?.toString();
        final extras = [type, code]
            .where((e) => e != null && e!.isNotEmpty)
            .join(' / ');
        if (message != null && message.isNotEmpty) {
          return 'OpenAI HTTP $statusCode：$message'
              '${extras.isEmpty ? '' : ' ($extras)'}';
        }
      }
    } catch (_) {}
    return 'OpenAI HTTP $statusCode：$raw';
  }
}


class GeminiAnalyzer {
  Future<Map<String, dynamic>> analyze({
    required String apiKey,
    required String model,
    required NewsItem item,
  }) async {
    if (apiKey.trim().isEmpty) throw Exception('尚未設定 Gemini API Key');
    if (item.body.length < 50) throw Exception('新聞正文擷取不足');

    final schema = _analysisSchema();

    const instructions = """
你是台股事件驅動研究員。根據新聞本身分析可能的台股影響，不喊單、不提供目標價。
使用繁體中文，嚴格區分新聞事實與推論。
「轉單」必須有原供應商受阻、客戶改單、產能替代或供應鏈重分配證據；需求增加不等於轉單。
若判斷不是轉單，transfer_order.is_transfer_order 必須為 false，且 transfer_order.beneficiaries 必須回傳空陣列 []。
「稀缺題材」要指出稀缺的是什麼、原因、可能持續時間與潛在受惠者。
檢查財報、營收、訂單、漲價、政策、產能、供應鏈、匯率、利率、原物料與產業趨勢。
股票代號不確定就留空字串，不可猜。
一次性消息不要誇大成長期趨勢。
""";

    final bodyText =
        item.body.substring(0, item.body.length > 16000 ? 16000 : item.body.length);

    final prompt =
        '新聞來源：${newsSourceLabelForUrl(item.url)}\n'
        '新聞標題：${item.title}\n發布時間：${item.publishedAt ?? '未知'}\n'
        '原文：${item.url}\n\n新聞正文：\n$bodyText';

    return _requestJson(
      apiKey: apiKey,
      model: model,
      systemInstruction: instructions,
      prompt: prompt,
      schema: schema,
      timeout: const Duration(seconds: 90),
    );
  }

  Future<String> testConnection({
    required String apiKey,
    required String model,
  }) async {
    if (apiKey.trim().isEmpty) throw Exception('尚未設定 Gemini API Key');

    // 不只測一般文字回覆，也實際測一次 JSON structured output / fallback，
    // 避免「測試成功但正式新聞分析失敗」。
    final result = await _requestJson(
      apiKey: apiKey,
      model: model,
      systemInstruction: '你是 API 連線測試器，只依照要求回傳 JSON。',
      prompt: '請回傳 status=OK。',
      schema: {
        'type': 'object',
        'properties': {
          'status': {'type': 'string'}
        },
        'required': ['status'],
        'additionalProperties': false,
      },
      timeout: const Duration(seconds: 30),
    );

    final status = result['status']?.toString() ?? '';
    if (status.toUpperCase() != 'OK') {
      throw Exception('Gemini 已連線，但 JSON 測試回傳異常：$result');
    }

    return '連線成功：${model.trim()} 可使用 Gemini API 與 JSON 分析';
  }

  Future<Map<String, dynamic>> _requestJson({
    required String apiKey,
    required String model,
    required String systemInstruction,
    required String prompt,
    required Map<String, dynamic> schema,
    required Duration timeout,
  }) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '${Uri.encodeComponent(model)}:generateContent',
    );

    final headers = {
      'Content-Type': 'application/json',
      'x-goog-api-key': apiKey,
    };

    Map<String, dynamic> baseBody(String userPrompt) => {
          'system_instruction': {
            'parts': [
              {'text': systemInstruction}
            ]
          },
          'contents': [
            {
              'parts': [
                {'text': userPrompt}
              ]
            }
          ],
        };

    // Gemini 的 generateContent / Structured Output 在不同模型與 API
    // 版本間格式曾有變動。這裡依序嘗試三種方式：
    //
    // 1. Legacy generateContent:
    //    responseMimeType + responseSchema
    // 2. 新 responseFormat，mimeType 使用 protobuf enum 名稱 APPLICATION_JSON
    // 3. 完全不使用 structured-output 參數，只用 prompt 強制純 JSON
    //
    // 只有 INVALID_ARGUMENT / HTTP 400 才會自動換下一種格式；
    // 401/403/404/429 等真正的 Key、模型、額度錯誤會直接回報。

    final attempts = <Map<String, dynamic>>[
      {
        ...baseBody(prompt),
        'generationConfig': {
          'temperature': 0.2,
          'responseMimeType': 'application/json',
          'responseSchema': schema,
        },
      },
      {
        ...baseBody(prompt),
        'generationConfig': {
          'temperature': 0.2,
          'responseFormat': {
            'text': {
              'mimeType': 'APPLICATION_JSON',
              'schema': schema,
            }
          },
        },
      },
      {
        ...baseBody(
          '$prompt\n\n'
          '請只輸出一個合法 JSON object，不要 Markdown、不要 ```json code fence、'
          '不要解釋文字。JSON 必須符合以下 schema：\n${jsonEncode(schema)}',
        ),
        'generationConfig': {
          'temperature': 0.2,
        },
      },
    ];

    String? last400;

    for (var i = 0; i < attempts.length; i++) {
      final r = await http
          .post(
            uri,
            headers: headers,
            body: jsonEncode(attempts[i]),
          )
          .timeout(timeout);

      final raw = utf8.decode(r.bodyBytes);

      if (r.statusCode >= 200 && r.statusCode < 300) {
        final payload = jsonDecode(raw) as Map<String, dynamic>;
        final output = _extractText(payload);

        if (output.trim().isEmpty) {
          if (i < attempts.length - 1) continue;
          throw Exception('Gemini 沒有回傳可解析的分析結果');
        }

        try {
          return _decodeJsonObject(output);
        } catch (e) {
          // 若 structured output 回覆格式仍不符，繼續嘗試 fallback。
          if (i < attempts.length - 1) continue;
          throw Exception('Gemini 回傳內容不是合法 JSON：$e\n$output');
        }
      }

      final message = _apiErrorMessage(r.statusCode, raw);

      if (r.statusCode == 400 && i < attempts.length - 1) {
        last400 = message;
        continue;
      }

      throw Exception(message);
    }

    throw Exception(last400 ?? 'Gemini JSON 分析失敗');
  }

  Map<String, dynamic> _decodeJsonObject(String output) {
    var value = output.trim();

    // 防止模型在 fallback 模式包上 Markdown code fence。
    if (value.startsWith('```')) {
      value = value.replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
      value = value.replaceFirst(RegExp(r'\s*```$'), '');
      value = value.trim();
    }

    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}

    // 最後再從文字中擷取最外層 JSON object。
    final first = value.indexOf('{');
    final last = value.lastIndexOf('}');
    if (first >= 0 && last > first) {
      final decoded = jsonDecode(value.substring(first, last + 1));
      if (decoded is Map) return decoded.cast<String, dynamic>();
    }

    throw const FormatException('找不到 JSON object');
  }

  Map<String, dynamic> _analysisSchema() => {
        'type': 'object',
        'properties': {
          'sentiment': {
            'type': 'string',
            'enum': ['利多', '偏多', '中性', '偏空', '利空']
          },
          'sentiment_score': {'type': 'integer', 'minimum': -2, 'maximum': 2},
          'time_horizon': {
            'type': 'array',
            'items': {'type': 'string', 'enum': ['短線', '中期', '長期']}
          },
          'core_conclusion': {'type': 'string'},
          'event_types': {'type': 'array', 'items': {'type': 'string'}},
          'key_points': {'type': 'array', 'items': {'type': 'string'}},
          'transfer_order': {
            'type': 'object',
            'properties': {
              'is_transfer_order': {'type': 'boolean'},
              'evidence': {'type': 'string'},
              'beneficiaries': {'type': 'array', 'items': {'type': 'string'}}
            },
            'required': ['is_transfer_order', 'evidence', 'beneficiaries'],
            'additionalProperties': false
          },
          'scarcity': {
            'type': 'object',
            'properties': {
              'is_scarcity_theme': {'type': 'boolean'},
              'scarce_item': {'type': 'string'},
              'why_scarce': {'type': 'string'},
              'duration': {'type': 'string'},
              'beneficiaries': {'type': 'array', 'items': {'type': 'string'}}
            },
            'required': [
              'is_scarcity_theme',
              'scarce_item',
              'why_scarce',
              'duration',
              'beneficiaries'
            ],
            'additionalProperties': false
          },
          'affected_companies': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'company': {'type': 'string'},
                'ticker': {'type': 'string'},
                'direction': {'type': 'string'},
                'reason': {'type': 'string'},
                'confidence': {
                  'type': 'integer',
                  'minimum': 0,
                  'maximum': 100
                }
              },
              'required': [
                'company',
                'ticker',
                'direction',
                'reason',
                'confidence'
              ],
              'additionalProperties': false
            }
          },
          'beneficiary_industries': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'negative_industries': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'catalysts': {'type': 'array', 'items': {'type': 'string'}},
          'risks': {'type': 'array', 'items': {'type': 'string'}},
          'watch_items': {'type': 'array', 'items': {'type': 'string'}},
          'confidence': {'type': 'integer', 'minimum': 0, 'maximum': 100}
        },
        'required': [
          'sentiment',
          'sentiment_score',
          'time_horizon',
          'core_conclusion',
          'event_types',
          'key_points',
          'transfer_order',
          'scarcity',
          'affected_companies',
          'beneficiary_industries',
          'negative_industries',
          'catalysts',
          'risks',
          'watch_items',
          'confidence'
        ],
        'additionalProperties': false
      };

  String _extractText(Map<String, dynamic> payload) {
    final candidates = payload['candidates'];
    if (candidates is List) {
      final chunks = <String>[];
      for (final c in candidates) {
        if (c is! Map) continue;
        final content = c['content'];
        if (content is! Map) continue;
        final parts = content['parts'];
        if (parts is! List) continue;
        for (final p in parts) {
          if (p is Map && p['text'] != null) {
            chunks.add(p['text'].toString());
          }
        }
      }
      return chunks.join();
    }
    return '';
  }

  String _apiErrorMessage(int statusCode, String raw) {
    try {
      final payload = jsonDecode(raw);
      if (payload is Map && payload['error'] is Map) {
        final error = payload['error'] as Map;
        final message = error['message']?.toString();
        final status = error['status']?.toString();
        final code = error['code']?.toString();
        final extras = [status, code]
            .where((e) => e != null && e!.isNotEmpty)
            .join(' / ');
        if (message != null && message.isNotEmpty) {
          return 'Gemini HTTP $statusCode：$message'
              '${extras.isEmpty ? '' : ' ($extras)'}';
        }
      }
    } catch (_) {}
    return 'Gemini HTTP $statusCode：$raw';
  }
}

class Notifications {
  Notifications._();
  static final instance = Notifications._();

  final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const macos = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const windows = WindowsInitializationSettings(
      appName: 'CTEE News Monitor',
      appUserModelId: 'JordanYeh.CTEENewsMonitor',
      guid: '2c0e8b69-9a16-4c36-99f8-1a71b58be266',
    );

    await plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: ios,
        macOS: macos,
        windows: windows,
      ),
    );
  }

  Future<void> requestPermission() async {
    if (Platform.isAndroid) {
      await plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } else if (Platform.isMacOS) {
      await plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  Future<void> show(NewsItem item) async {
    final a = item.analysis;
    final tags = <String>[];
    if (a != null) {
      tags.add(a['sentiment']?.toString() ?? '中性');
      final t = a['transfer_order'];
      final s = a['scarcity'];
      if (t is Map && t['is_transfer_order'] == true) tags.add('轉單');
      if (s is Map && s['is_scarcity_theme'] == true) tags.add('稀缺');
    }

    final time = timeText(item.publishedAt);
    final source = newsSourceLabelForUrl(item.url);
    final title = '[$source] ${time.isEmpty ? '' : '$time '}${item.title}';
    final conclusion =
        a?['core_conclusion']?.toString() ?? '$source 出現新新聞';
    final notificationBody =
        '${tags.isEmpty ? '' : '${tags.join('｜')}：'}$conclusion';

    final threadId =
        isMoneyDjNewsUrl(item.url) ? 'moneydj_industry_news' : 'ctee_stock_news';

    final details = NotificationDetails(
      android: const AndroidNotificationDetails(
        'finance_ai_news',
        '財經新聞 AI 監控',
        channelDescription: '工商時報與 MoneyDJ 新聞及 AI 分析',
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(threadIdentifier: threadId),
      macOS: DarwinNotificationDetails(threadIdentifier: threadId),
    );

    await plugin.show(
      id: item.url.hashCode & 0x7fffffff,
      title: title,
      body: notificationBody.length > 220
          ? '${notificationBody.substring(0, 217)}...'
          : notificationBody,
      notificationDetails: details,
      payload: item.url,
    );
  }

  String timeText(String? value) {
    final d = cteeTaipeiDateTime(value);
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}


class Monitor {
  final store = Store();
  final scraper = Scraper();
  final moneyDjScraper = MoneyDjScraper();
  final openAiAnalyzer = OpenAIAnalyzer();
  final geminiAnalyzer = GeminiAnalyzer();

  Future<String> run({bool background = false}) async {
    if (background && !(await store.enabled())) return '監控已停用';

    final cteeOn = await store.cteeEnabled();
    final moneyDjOn = await store.moneyDjEnabled();
    if (!cteeOn && !moneyDjOn) return '沒有啟用任何新聞來源';

    final messages = <String>[];

    if (cteeOn) {
      try {
        messages.add(await _runSource(
          sourceId: sourceCtee,
          sourceLabel: '工商時報',
          listing: scraper.listing,
          detail: scraper.detail,
          fetchBaselineDetails: true,
        ));
      } catch (e) {
        messages.add('工商時報檢查失敗：$e');
      }
    }

    if (moneyDjOn) {
      try {
        messages.add(await _runSource(
          sourceId: sourceMoneyDj,
          sourceLabel: 'MoneyDJ',
          listing: moneyDjScraper.listing,
          detail: moneyDjScraper.detail,
          fetchBaselineDetails: false,
        ));
      } catch (e) {
        messages.add('MoneyDJ 檢查失敗：$e');
      }
    }

    return messages.join(' ｜ ');
  }

  Future<String> _runSource({
    required String sourceId,
    required String sourceLabel,
    required Future<List<ListingItem>> Function() listing,
    required Future<NewsItem> Function(ListingItem) detail,
    required bool fetchBaselineDetails,
  }) async {
    final list = await listing();
    if (list.isEmpty) throw Exception('列表頁沒有解析到新聞連結');

    final history = await store.load();
    final sourceHistory = history
        .where((e) => newsSourceIdForUrl(e.url) == sourceId)
        .toList();

    final ignoredUrls = await store.ignoredNewsUrls();

    final known = <String>{
      ...sourceHistory.map((e) => e.url),
      ...ignoredUrls.where(
        (url) => newsSourceIdForUrl(url) == sourceId,
      ),
    };

    final provider = await store.provider();

    if (!(await store.initializedFor(sourceId))) {
      for (final x in list.reversed) {
        if (known.contains(x.url)) continue;

        if (fetchBaselineDetails) {
          try {
            final baseline = await detail(x);
            baseline.status = 'baseline';
            baseline.analysis = null;
            baseline.error = null;
            history.insert(0, baseline);
          } catch (_) {
            history.insert(0, NewsItem(
              url: x.url,
              title: x.title,
              publishedAt: x.publishedAt,
              discoveredAt: DateTime.now().toIso8601String(),
              metadataFetched: true,
              status: 'baseline',
            ));
          }
        } else {
          history.insert(0, NewsItem(
            url: x.url,
            title: x.title,
            publishedAt: x.publishedAt,
            discoveredAt: DateTime.now().toIso8601String(),
            // MoneyDJ 首次建立 baseline 時沒有進內頁，
            // 因此不能標記成 metadata 已完成。
            metadataFetched: false,
            status: 'baseline',
          ));
        }
      }
      await store.save(history);
      await store.setInitializedFor(sourceId);
      return '$sourceLabel 首次啟用：已建立 ${list.length} 篇基準，不推播既有新聞';
    }

    // v23：MoneyDJ 舊紀錄可能是 v22 首次 baseline 建立的，
    // 當時沒有進新聞內頁，因此作者會是空白。
    // 每次檢查最多補 20 篇目前列表中的 MoneyDJ 紀錄，
    // 不做 AI 分析、不發通知，只更新 metadata。
    var authorBackfilled = 0;

    if (sourceId == sourceMoneyDj) {
      for (final x in list) {
        if (authorBackfilled >= 20) break;

        final i = history.indexWhere((e) => e.url == x.url);
        if (i < 0) continue;

        final oldItem = history[i];
        final needsAuthor = (oldItem.author ?? '').trim().isEmpty;

        if (!needsAuthor && oldItem.metadataFetched) continue;

        try {
          final parsed = await detail(x);

          oldItem.title = parsed.title;
          oldItem.publishedAt = parsed.publishedAt ?? oldItem.publishedAt;
          oldItem.author = parsed.author;
          oldItem.tags = parsed.tags;
          oldItem.metadataFetched = true;

          // baseline 原本可能沒有正文；補 metadata 時順便留存，
          // 之後使用「重新分析」時可減少抓取失敗的影響。
          if (oldItem.body.trim().isEmpty &&
              parsed.body.trim().isNotEmpty) {
            oldItem.body = parsed.body;
          }

          authorBackfilled++;
        } catch (_) {
          // 抓取暫時失敗時不要把 metadataFetched 設成 true，
          // 下次檢查仍可重試。
        }
      }

      if (authorBackfilled > 0) {
        await store.save(history);
      }
    }

    final unseen = list.where((e) => !known.contains(e.url)).toList();
    if (unseen.isEmpty) {
      return '$sourceLabel：沒有新新聞｜解析 ${list.length} 篇'
          '${authorBackfilled > 0 ? '｜補齊 $authorBackfilled 篇作者/metadata' : ''}';
    }

    DateTime? latestKnownTime;
    for (final old in sourceHistory) {
      final dt = cteeTaipeiDateTime(old.publishedAt);
      if (dt == null) continue;
      if (latestKnownTime == null || dt.isAfter(latestKnownTime!)) {
        latestKnownTime = dt;
      }
    }

    // 如果使用者剛清除可見歷史，仍以清除前最後已知時間作為安全邊界。
    latestKnownTime ??= await store.clearCutoffFor(sourceId);

    final freshnessCutoff =
        latestKnownTime?.subtract(const Duration(minutes: 5));
    final apiKey = await store.apiKey();
    final model = await store.model();
    var analyzed = 0;
    var realNewCount = 0;
    var historicalAdded = 0;

    for (final x in unseen.reversed) {
      NewsItem item;
      try {
        item = await detail(x);
      } catch (e) {
        item = NewsItem(
          url: x.url,
          title: x.title,
          publishedAt: x.publishedAt,
          discoveredAt: DateTime.now().toIso8601String(),
          metadataFetched: true,
          status: 'baseline',
          error: '新聞內頁確認失敗：$e',
        );
        history.insert(0, item);
        historicalAdded++;
        await store.save(history);
        continue;
      }

      final articleTime = cteeTaipeiDateTime(item.publishedAt);
      final isClearlyOld = freshnessCutoff != null &&
          articleTime != null &&
          articleTime.isBefore(freshnessCutoff);

      if (isClearlyOld) {
        item.status = 'baseline';
        item.analysis = null;
        item.error = null;
        history.insert(0, item);
        historicalAdded++;
        await store.save(history);
        continue;
      }

      if (articleTime == null && latestKnownTime != null) {
        item.status = 'baseline';
        item.analysis = null;
        item.error = '無法確認新聞發布時間，因此未自動通知';
        history.insert(0, item);
        historicalAdded++;
        await store.save(history);
        continue;
      }

      realNewCount++;
      item.status = 'analyzing';
      history.insert(0, item);
      await store.save(history);

      try {
        item.analysis = await _analyzeWithProvider(
          provider: provider,
          apiKey: apiKey,
          model: model,
          item: item,
        );
        item.status = 'done';
        item.error = null;
        analyzed++;
      } catch (e) {
        item.status = 'error';
        item.error = e.toString();
      }

      await store.save(history);
      try {
        await Notifications.instance.show(item);
      } catch (_) {}
    }

    if (realNewCount == 0) {
      return '$sourceLabel：沒有真正的新新聞｜解析 ${list.length} 篇'
          '${authorBackfilled > 0 ? '｜補齊 $authorBackfilled 篇作者/metadata' : ''}'
          '${historicalAdded > 0 ? '｜略過 $historicalAdded 篇舊文章' : ''}';
    }

    return '$sourceLabel：新增 $realNewCount 篇，'
        '${aiProviderLabel(provider)} 完成 $analyzed 篇分析'
        '${authorBackfilled > 0 ? '｜補齊 $authorBackfilled 篇作者/metadata' : ''}'
        '${historicalAdded > 0 ? '｜略過 $historicalAdded 篇舊文章' : ''}';
  }

  Future<String> retryUnfinishedAnalysis() async {
    final history = await store.load();
    final candidates = history
        .where((e) =>
            e.analysis == null &&
            e.status != 'baseline' &&
            e.body.trim().length >= 50)
        .toList();

    if (candidates.isEmpty) {
      return '沒有需要重試的 AI 分析';
    }

    final provider = await store.provider();
    final apiKey = await store.apiKey();
    final model = await store.model();
    var ok = 0;
    var failed = 0;

    for (final item in candidates) {
      item.status = 'analyzing';
      item.error = null;
      await store.save(history);

      try {
        item.analysis = await _analyzeWithProvider(
          provider: provider,
          apiKey: apiKey,
          model: model,
          item: item,
        );
        item.status = 'done';
        item.error = null;
        ok++;
      } catch (e) {
        item.status = 'error';
        item.error = e.toString();
        failed++;
      }
      await store.save(history);
    }

    return '${aiProviderLabel(provider)} 重試完成：成功 $ok 篇，失敗 $failed 篇';
  }

  Future<String> reanalyzeArticle(String url) async {
    final history = await store.load();
    final index = history.indexWhere((e) => e.url == url);
    if (index < 0) {
      throw Exception('找不到這篇新聞的本機紀錄');
    }

    final item = history[index];
    final previousAnalysis = item.analysis;
    final previousStatus = item.status;
    final previousError = item.error;

    // 重新分析前，先重新進新聞內頁抓取最新內容與 metadata。
    // 若網站暫時抓取失敗，但本機已有足夠正文，仍可用舊正文重新分析。
    try {
      final listingItem =
          ListingItem(item.url, item.title, item.publishedAt);
      final detail = isMoneyDjNewsUrl(item.url)
          ? await moneyDjScraper.detail(listingItem)
          : await scraper.detail(listingItem);

      item.title = detail.title;
      item.publishedAt = detail.publishedAt ?? item.publishedAt;
      item.author = detail.author;
      item.tags = detail.tags;
      item.metadataFetched = true;

      if (detail.body.trim().length >= 50) {
        item.body = detail.body;
      }
    } catch (e) {
      if (item.body.trim().length < 50) {
        throw Exception('重新讀取新聞頁失敗，而且本機沒有足夠正文：$e');
      }
    }

    if (item.body.trim().length < 50) {
      throw Exception('新聞正文不足，無法重新分析');
    }

    final provider = await store.provider();
    final apiKey = await store.apiKey();
    final model = await store.model();

    item.status = 'analyzing';
    item.error = null;
    await store.updateNewsItem(item);

    try {
      final newAnalysis = await _analyzeWithProvider(
        provider: provider,
        apiKey: apiKey,
        model: model,
        item: item,
      );

      item.analysis = newAnalysis;
      item.status = 'done';
      item.error = null;
      await store.updateNewsItem(item);

      return '${aiProviderLabel(provider)} 已重新分析：${item.title}';
    } catch (e) {
      // 重新分析失敗時保留上一版成功結果，不讓舊分析被破壞。
      item.analysis = previousAnalysis;
      item.status = previousAnalysis != null ? 'done' : previousStatus;
      item.error = previousAnalysis != null ? previousError : e.toString();
      await store.updateNewsItem(item);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _analyzeWithProvider({
    required AiProvider provider,
    required String apiKey,
    required String model,
    required NewsItem item,
  }) {
    switch (provider) {
      case AiProvider.gemini:
        return geminiAnalyzer.analyze(
          apiKey: apiKey,
          model: model,
          item: item,
        );
      case AiProvider.openai:
        return openAiAnalyzer.analyze(
          apiKey: apiKey,
          model: model,
          item: item,
        );
    }
  }
}

@pragma('vm:entry-point')

void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await Notifications.instance.init();
      await Monitor().run(background: true);
      return true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> initBackground() async {
  if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) return;

  await Workmanager().initialize(callbackDispatcher);

  if (Platform.isAndroid) {
    await Workmanager().registerPeriodicTask(
      'tw-stock-news-ai-monitor',
      backgroundTaskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  } else if (Platform.isIOS) {
    await Workmanager().registerPeriodicTask(
      backgroundTaskName,
      backgroundTaskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } else if (Platform.isMacOS) {
    await Workmanager().registerPeriodicTask(
      'tw-stock-news-ai-monitor',
      backgroundTaskName,
      frequency: const Duration(minutes: 15),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 在第一個畫面顯示前先讀取外觀設定，避免啟動時先閃一下明亮模式。
  try {
    appThemeMode.value = await Store().themeMode();
  } catch (_) {
    appThemeMode.value = ThemeMode.light;
  }

  await Notifications.instance.init();
  try {
    await initBackground();
  } catch (_) {}
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'TW Stock News AI Monitor',
          themeMode: themeMode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: const HomePage(),
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final store = Store();
  final monitor = Monitor();

  List<NewsItem> items = [];
  Timer? timer;
  bool checking = false;
  bool retryingAi = false;
  final Set<String> reanalyzingUrls = <String>{};
  bool enabled = true;
  String status = '準備中';

  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    enabled = await store.enabled();
    await reload();
    restartTimer();
    await check();
  }

  Future<void> reload() async {
    items = await store.load();
    if (mounted) setState(() {});
  }

  void restartTimer() {
    timer?.cancel();
    if (enabled) {
      timer = Timer.periodic(const Duration(seconds: 60), (_) => check());
    }
  }

  Future<void> check() async {
    // 新聞重新分析進行中時，不同篇可彼此平行；
    // 但暫停整批新聞檢查，避免另一個整份 history save() 工作插入。
    if (checking || !enabled || retryingAi || reanalyzingUrls.isNotEmpty) {
      return;
    }
    checking = true;
    status = '正在檢查新聞來源…';
    if (mounted) setState(() {});

    try {
      status = await monitor.run();
    } catch (e) {
      status = '檢查失敗：$e';
    } finally {
      checking = false;
      await reload();
    }
  }

  Future<void> retryAi() async {
    if (retryingAi || checking || reanalyzingUrls.isNotEmpty) return;
    retryingAi = true;
    status = '正在重試未完成的 AI 分析…';
    if (mounted) setState(() {});

    try {
      status = await monitor.retryUnfinishedAnalysis();
    } catch (e) {
      status = 'AI 重試失敗：$e';
    } finally {
      retryingAi = false;
      await reload();
    }
  }

  Future<void> reanalyzeOne(NewsItem item) async {
    if (checking ||
        retryingAi ||
        reanalyzingUrls.contains(item.url)) {
      return;
    }

    reanalyzingUrls.add(item.url);
    status = '正在重新分析「${item.title}」…';
    if (mounted) setState(() {});

    try {
      status = await monitor.reanalyzeArticle(item.url);
    } catch (e) {
      status = '重新分析失敗：$e';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('「${item.title}」重新分析失敗：$e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      reanalyzingUrls.remove(item.url);
      await reload();
    }
  }

  Future<void> openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsPage(store: store)),
    );
    enabled = await store.enabled();
    restartTimer();
    await reload();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('台股新聞AI監控'),
        actions: [
          IconButton(
            tooltip: '設定',
            onPressed: openSettings,
            icon: const Icon(Icons.settings),
          )
        ],
      ),
      body: RefreshIndicator(
        onRefresh: check,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              color: enabled
                  ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.35)
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${enabled ? '監控中' : '已暫停'}｜$status'),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed:
                              retryingAi || reanalyzingUrls.isNotEmpty
                                  ? null
                                  : retryAi,
                          icon: retryingAi
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.psychology_alt),
                          label: const Text('重試 AI'),
                        ),
                        FilledButton.icon(
                          onPressed:
                              checking || reanalyzingUrls.isNotEmpty
                                  ? null
                                  : check,
                          icon: checking
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.refresh),
                          label: const Text('立即檢查'),
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: Text('尚無新聞')),
              ),
            ...items.map(
              (e) => NewsCard(
                key: ValueKey(e.url),
                item: e,
                reanalyzing: reanalyzingUrls.contains(e.url),
                onReanalyze: () => reanalyzeOne(e),
              ),
            )
          ],
        ),
      ),
    );
  }
}

class NewsCard extends StatelessWidget {
  const NewsCard({
    super.key,
    required this.item,
    required this.reanalyzing,
    required this.onReanalyze,
  });

  final NewsItem item;
  final bool reanalyzing;
  final VoidCallback onReanalyze;

  Color _sentimentColor(BuildContext context, String sentiment) {
    // 台股配色：漲紅跌綠。
    switch (sentiment) {
      case '利多':
        return const Color(0xFFD93025);
      case '偏多':
        return const Color(0xFFE85D55);
      case '利空':
        return const Color(0xFF0F9D58);
      case '偏空':
        return const Color(0xFF45A36B);
      default:
        return const Color(0xFF5F6368);
    }
  }

  Color _sentimentBackground(BuildContext context, String sentiment) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    switch (sentiment) {
      case '利多':
      case '偏多':
        return isDark ? const Color(0xFF4A2020) : const Color(0xFFFDEEEE);
      case '利空':
      case '偏空':
        return isDark ? const Color(0xFF123C2A) : const Color(0xFFE9F7EF);
      default:
        return isDark ? const Color(0xFF2E3540) : const Color(0xFFF1F3F4);
    }
  }

  Color _cardBackground(BuildContext context, String sentiment) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    switch (sentiment) {
      case '利多':
      case '偏多':
        return isDark ? const Color(0xFF1D1212) : const Color(0xFFFFFCFC);
      case '利空':
      case '偏空':
        return isDark ? const Color(0xFF101A15) : const Color(0xFFFBFEFC);
      default:
        return isDark ? const Color(0xFF171A1F) : const Color(0xFFFFFFFF);
    }
  }

  String _sentimentDisplayLabel(String sentiment) {
    switch (sentiment) {
      case '利多':
        return '▲▲ 強利多';
      case '偏多':
        return '▲ 偏多';
      case '利空':
        return '▼▼ 強利空';
      case '偏空':
        return '▼ 偏空';
      case '中性':
        return '● 中性';
      default:
        return '● 未分析';
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = item.analysis;
    final t = a?['transfer_order'];
    final s = a?['scarcity'];

    final sentiment = a?['sentiment']?.toString() ?? '未分析';
    final transfer = t is Map && t['is_transfer_order'] == true;
    final scarcity = s is Map && s['is_scarcity_theme'] == true;

    final keyPoints = (a?['key_points'] is List)
        ? (a!['key_points'] as List).map((e) => e.toString()).toList()
        : <String>[];
    final risks = (a?['risks'] is List)
        ? (a!['risks'] as List).map((e) => e.toString()).toList()
        : <String>[];
    final watch = (a?['watch_items'] is List)
        ? (a!['watch_items'] as List).map((e) => e.toString()).toList()
        : <String>[];

    final baseColor = a == null
        ? const Color(0xFF9AA0A6)
        : _sentimentColor(context, sentiment);
    final cardBg = a == null
        ? (Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF171A1F)
            : const Color(0xFFFFFFFF))
        : _cardBackground(context, sentiment);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1.2,
      color: cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: baseColor.withOpacity(a == null ? 0.18 : 0.32),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: baseColor,
                width: 6,
              ),
            ),
          ),
          child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            height: 1.28,
                          ),
                    ),
                    const SizedBox(height: 7),

                    // 時間 / 媒體 / 作者
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Icon(
                          Icons.schedule,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        Text(
                          _displayTime(item.publishedAt ?? item.discoveredAt),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          '／ ${newsSourceLabelForUrl(item.url)}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: isMoneyDjNewsUrl(item.url)
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                              ),
                        ),
                        if ((item.author ?? '').trim().isNotEmpty)
                          Text(
                            '／ ${item.author}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),

                    const SizedBox(height: 9),

                    // 新聞原始標籤
                    if (item.tags.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: item.tags
                            .map(
                              (tag) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(7),
                                  border: Border.all(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant,
                                  ),
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerLowest,
                                ),
                                child: Text(
                                  '#$tag',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                            )
                            .toList(),
                      ),

                    if (item.tags.isNotEmpty) const SizedBox(height: 10),

                    // AI 情緒 + 題材徽章
                    if (a != null)
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: _sentimentBackground(context, sentiment),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: baseColor.withOpacity(0.65),
                              ),
                            ),
                            child: Text(
                              _sentimentDisplayLabel(sentiment),
                              style: TextStyle(
                                color: baseColor,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (transfer)
                            _highlightBadge(
                              context,
                              icon: Icons.swap_horiz,
                              label: '轉單受惠',
                              background: const Color(0xFFFFF3CD),
                              foreground: const Color(0xFF8A5A00),
                            ),
                          if (scarcity)
                            _highlightBadge(
                              context,
                              icon: Icons.bolt,
                              label: '稀缺題材',
                              background: const Color(0xFFEADCF8),
                              foreground: const Color(0xFF6A1B9A),
                            ),
                        ],
                      ),

                    if (a != null) const SizedBox(height: 10),

                    // AI 核心結論
                    if (a != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: _sentimentBackground(context, sentiment),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.auto_awesome,
                              size: 18,
                              color: baseColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                a['core_conclusion']?.toString() ?? '',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      height: 1.5,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    if (a == null && item.status == 'baseline')
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Text('啟動前既有文章，尚未進行 AI 分析'),
                      ),

                    if (item.status == 'error')
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          'AI / 處理錯誤：${item.error ?? '未知錯誤'}',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),

                    const SizedBox(height: 10),

                    Row(
                      children: [
                        if (a != null)
                          Expanded(
                            child: Text(
                              '完整分析  ｜ 信心 ${a['confidence'] ?? 0}%',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          )
                        else
                          const Spacer(),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            OutlinedButton.icon(
                              onPressed: reanalyzing ? null : onReanalyze,
                              icon: reanalyzing
                                  ? const SizedBox(
                                      width: 15,
                                      height: 15,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.auto_fix_high, size: 17),
                              label: Text(
                                reanalyzing ? '分析中…' : '重新分析',
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () => launchUrl(
                                Uri.parse(item.url),
                                mode: LaunchMode.externalApplication,
                              ),
                              icon: const Icon(Icons.open_in_new, size: 16),
                              label: const Text('原文'),
                            ),
                          ],
                        ),
                      ],
                    ),

                    if (a != null)
                      Theme(
                        data: Theme.of(context).copyWith(
                          dividerColor: Colors.transparent,
                        ),
                        child: ExpansionTile(
                          key: PageStorageKey<String>(
                            'analysis-${item.url}',
                          ),
                          tilePadding: EdgeInsets.zero,
                          initiallyExpanded: false,
                          title: const Text('展開詳細分析'),
                          childrenPadding: EdgeInsets.zero,
                          children: [
                            _sectionCard(
                              context,
                              title: '新聞重點',
                              icon: Icons.summarize,
                              lines: keyPoints,
                            ),
                            if (t is Map)
                              _sectionCard(
                                context,
                                title: '轉單判斷',
                                icon: Icons.swap_horiz,
                                lines: [
                                  transfer ? '判斷：是' : '判斷：否',
                                  t['evidence']?.toString() ?? '',
                                  if (transfer &&
                                      t['beneficiaries'] is List &&
                                      (t['beneficiaries'] as List).isNotEmpty)
                                    '可能轉單受惠者：'
                                        '${(t['beneficiaries'] as List).join('、')}',
                                ],
                              ),
                            if (s is Map)
                              _sectionCard(
                                context,
                                title: '稀缺題材',
                                icon: Icons.bolt,
                                lines: [
                                  scarcity
                                      ? '判斷：是｜${s['scarce_item'] ?? ''}'
                                      : '判斷：否',
                                  s['why_scarce']?.toString() ?? '',
                                  if ((s['duration']?.toString() ?? '').isNotEmpty)
                                    '可能持續：${s['duration']}',
                                ],
                              ),
                            _sectionCard(
                              context,
                              title: '風險',
                              icon: Icons.warning_amber_rounded,
                              lines: risks,
                            ),
                            _sectionCard(
                              context,
                              title: '後續觀察',
                              icon: Icons.visibility_outlined,
                              lines: watch,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
  }

  Widget _highlightBadge(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? foreground.withOpacity(0.20) : background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: isDark ? background : foreground,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard(
    BuildContext context, {
    required String title,
    required IconData icon,
    required List<String> lines,
  }) {
    final usable = lines.where((e) => e.trim().isNotEmpty).toList();
    if (usable.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17),
              const SizedBox(width: 7),
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ...usable.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $line'),
            ),
          ),
        ],
      ),
    );
  }

  String _displayTime(String raw) {
    final d = cteeTaipeiDateTime(raw);
    if (d == null) return raw;

    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');

    return '$y.$m.$day / $hh:$mm';
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});
  final Store store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}


class _SettingsPageState extends State<SettingsPage> {
  final openAiKeyCtrl = TextEditingController();
  final openAiModelCtrl = TextEditingController();
  final geminiKeyCtrl = TextEditingController();
  final geminiModelCtrl = TextEditingController();

  bool enabled = true;
  bool cteeEnabled = true;
  bool moneyDjEnabled = true;
  bool obscureOpenAi = true;
  bool obscureGemini = true;
  bool loaded = false;
  bool testingApi = false;
  bool clearingNews = false;
  String apiTestResult = '';
  AiProvider provider = AiProvider.openai;
  ThemeMode themeMode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    openAiKeyCtrl.dispose();
    openAiModelCtrl.dispose();
    geminiKeyCtrl.dispose();
    geminiModelCtrl.dispose();
    super.dispose();
  }

  Future<void> load() async {
    provider = await widget.store.provider();
    openAiKeyCtrl.text = await widget.store.openAiApiKey();
    openAiModelCtrl.text = await widget.store.openAiModel();
    geminiKeyCtrl.text = await widget.store.geminiApiKey();
    geminiModelCtrl.text = await widget.store.geminiModel();
    enabled = await widget.store.enabled();
    cteeEnabled = await widget.store.cteeEnabled();
    moneyDjEnabled = await widget.store.moneyDjEnabled();
    themeMode = await widget.store.themeMode();
    loaded = true;
    if (mounted) setState(() {});
  }

  Future<void> save() async {
    await widget.store.setProvider(provider);
    await widget.store.setOpenAiApiKey(openAiKeyCtrl.text);
    await widget.store.setOpenAiModel(openAiModelCtrl.text);
    await widget.store.setGeminiApiKey(geminiKeyCtrl.text);
    await widget.store.setGeminiModel(geminiModelCtrl.text);
    await widget.store.setEnabled(enabled);
    await widget.store.setCteeEnabled(cteeEnabled);
    await widget.store.setMoneyDjEnabled(moneyDjEnabled);
    await widget.store.setThemeMode(themeMode);
    appThemeMode.value = themeMode;
    await Notifications.instance.requestPermission();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('設定已儲存')));
    }
  }

  Future<void> testApi() async {
    testingApi = true;
    apiTestResult = '正在測試 ${aiProviderLabel(provider)} API…';
    if (mounted) setState(() {});

    try {
      await widget.store.setProvider(provider);
      await widget.store.setOpenAiApiKey(openAiKeyCtrl.text);
      await widget.store.setOpenAiModel(openAiModelCtrl.text);
      await widget.store.setGeminiApiKey(geminiKeyCtrl.text);
      await widget.store.setGeminiModel(geminiModelCtrl.text);

      switch (provider) {
        case AiProvider.openai:
          apiTestResult = await OpenAIAnalyzer().testConnection(
            apiKey: openAiKeyCtrl.text,
            model: openAiModelCtrl.text.trim().isEmpty
                ? 'gpt-5.4-mini'
                : openAiModelCtrl.text.trim(),
          );
          break;
        case AiProvider.gemini:
          apiTestResult = await GeminiAnalyzer().testConnection(
            apiKey: geminiKeyCtrl.text,
            model: geminiModelCtrl.text.trim().isEmpty
                ? 'gemini-3.5-flash-lite'
                : geminiModelCtrl.text.trim(),
          );
          break;
      }
    } catch (e) {
      apiTestResult = '測試失敗：$e';
    } finally {
      testingApi = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> clearFetchedNews() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('清除已抓取新聞？'),
          content: const Text(
            '這會完整清除所有已抓取新聞相關資料，包括：\n'
            '• 新聞清單\n'
            '• 已儲存正文\n'
            '• AI 分析結果\n'
            '• 來源初始化紀錄\n\n'
            'OpenAI / Gemini API Key、模型、新聞來源開關與外觀設定都會保留。\n\n'
            '清除後，下一次檢查會視為全新開始，重新建立目前網站新聞的基準。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清除'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() => clearingNews = true);

    try {
      final count = await widget.store.clearFetchedNews();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count == 0
                ? '已完整清除新聞相關紀錄'
                : '已完整清除 $count 篇新聞與相關紀錄。',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('清除新聞失敗：$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => clearingNews = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final activeKeyCtrl =
        provider == AiProvider.openai ? openAiKeyCtrl : geminiKeyCtrl;
    final activeModelCtrl =
        provider == AiProvider.openai ? openAiModelCtrl : geminiModelCtrl;
    final activeObscure =
        provider == AiProvider.openai ? obscureOpenAi : obscureGemini;
    final activeDefaultModel =
        provider == AiProvider.openai ? 'gpt-5.4-mini' : 'gemini-3.5-flash-lite';

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              '啟用新聞監控',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: const Text(
                'App 開啟時每 60 秒檢查已啟用的新聞來源\n'
                'Android/iOS 背景工作由系統排程，不能保證每 60 秒執行；'
                'iPhone 尤其無法保證即時。\nWindows/macOS 只要 App 持續執行，'
                '前景監控會每 60 秒檢查。'
            ),
            value: enabled,
            onChanged: (v) => setState(() => enabled = v),
          ),
          const SizedBox(height: 12),
          Divider(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '新聞來源',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.newspaper),
            title: const Text('工商時報'),
            subtitle: const Text('台股市場'),
            value: cteeEnabled,
            onChanged: enabled ? (v) => setState(() => cteeEnabled = v) : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.factory_outlined),
            title: const Text('MoneyDJ 理財網'),
            subtitle: const Text('產業情報'),
            value: moneyDjEnabled,
            onChanged: enabled ? (v) => setState(() => moneyDjEnabled = v) : null,
          ),
          const SizedBox(height: 16),
          Divider(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '外觀',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.light,
                label: Text('明亮'),
                icon: Icon(Icons.light_mode),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text('暗色'),
                icon: Icon(Icons.dark_mode),
              ),
              ButtonSegment(
                value: ThemeMode.system,
                label: Text('跟隨系統'),
                icon: Icon(Icons.brightness_auto),
              ),
            ],
            selected: {themeMode},
            onSelectionChanged: (values) async {
              final selected = values.first;
              setState(() => themeMode = selected);

              // 立即套用，並立即寫入本機設定。
              appThemeMode.value = selected;
              await widget.store.setThemeMode(selected);
            },
          ),
          const SizedBox(height: 8),
          Text(
            '目前：${appThemeModeLabel(themeMode)}。切換後立即套用，下次啟動會保留。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Divider(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'AI 供應商',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SegmentedButton<AiProvider>(
            segments: const [
              ButtonSegment(
                value: AiProvider.openai,
                label: Text('OpenAI'),
                icon: Icon(Icons.auto_awesome),
              ),
              ButtonSegment(
                value: AiProvider.gemini,
                label: Text('Gemini'),
                icon: Icon(Icons.stars),
              ),
            ],
            selected: {provider},
            onSelectionChanged: (values) {
              setState(() {
                provider = values.first;
                apiTestResult = '';
              });
            },
          ),
          const SizedBox(height: 8),
          Text(
            '已選擇：${aiProviderLabel(provider)}。OpenAI 與 Gemini 的 Key / Model 會分開保存，可隨時切換。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: activeKeyCtrl,
            obscureText: activeObscure,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: '${aiProviderLabel(provider)} API Key',
              helperText: '只存在本機安全儲存區',
              suffixIcon: IconButton(
                icon: Icon(activeObscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() {
                  if (provider == AiProvider.openai) {
                    obscureOpenAi = !obscureOpenAi;
                  } else {
                    obscureGemini = !obscureGemini;
                  }
                }),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: activeModelCtrl,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: '${aiProviderLabel(provider)} model',
              helperText: '預設 $activeDefaultModel',
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: save,
                  child: const Text('儲存並開啟通知權限'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: testingApi ? null : testApi,
                  icon: testingApi
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.api),
                  label: Text('測試 ${aiProviderLabel(provider)} API'),
                ),
              ),
            ],
          ),
          if (apiTestResult.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              apiTestResult,
              style: TextStyle(
                color: apiTestResult.startsWith('連線成功')
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 18),
          Text(
            provider == AiProvider.gemini
                ? '提示：Gemini 可能有免費層與速率限制，但仍需自行在 Google AI Studio / API 專案管理可用額度。'
                : '提示：若出現 no credits 或 insufficient_quota，需到 API billing 充值。',
          ),
          const SizedBox(height: 24),
          Divider(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '資料管理',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '完整清除新聞歷史、正文、AI 分析與來源初始化紀錄；API Key、模型、新聞來源開關與外觀設定會保留。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: clearingNews ? null : clearFetchedNews,
              icon: clearingNews
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_sweep_outlined),
              label: Text(
                clearingNews ? '正在清除…' : '清除已抓取新聞',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
          )
        ],
      ),
    );
  }
}
