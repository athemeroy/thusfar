// JavaScript-only Flutter Web entrypoint. Browser DOM APIs are intentionally
// confined here; native targets compile lib/main.dart instead.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyEvent, KeyUpEvent, LogicalKeyboardKey;
import 'package:thusfar_core/thusfar_core.dart' as knowledge;
import 'package:thusfar_core/chapter_verdicts.dart' show titleCheckPending;

import '../data/library_zip.dart';
import '../data/restore_report.dart';
import '../data/shelf_organization.dart';
import '../data/reading_activity.dart';
import '../screens/reading_activity_screen.dart';
import '../reading/read_aloud.dart';
import '../reading/auto_page_turner.dart';
import '../ui/restore_report_view.dart';
import '../ui/theme.dart';
import '../ui/workspace_navigation.dart';
import 'web_notes_center.dart';
import 'web_activity_route.dart';
import '../reader/image_viewer.dart';
import '../reader/source_selection.dart';
import 'reading_boundary.dart';
import 'web_ai_panel.dart';
import 'web_ai_engine.dart';
import 'web_ask_panel.dart';
import 'web_model_session.dart';
import 'web_storage.dart';
import 'web_reader_search.dart';
import 'web_recovery_page.dart';
import 'webdav_sync.dart';

part 'shelf/web_shelf.dart';
part 'common/web_common.dart';
part 'reader/web_reader.dart';
