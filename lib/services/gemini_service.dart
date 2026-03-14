import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class GeminiService {
  GeminiService._();
  static final GeminiService instance = GeminiService._();

  List<Map<String, dynamic>> _chatHistory = [];
  bool _initialized = false;
  
  String get _apiKey => dotenv.env['GEMINI_API_KEY'] ?? '';

  // Using raw HTTP with accurate v1beta and model endpoint based on user instruction
  String _getApiUrl(String model) {
    return 'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$_apiKey';
  }

  void init() {
    if (_initialized) return;
    _chatHistory = [];
    _initialized = true;
  }

  void startChat({String? contextData}) {
    if (!_initialized) init();
    _chatHistory = [];

    String basePrompt = "You are SpendX AI, a helpful personal finance assistant. Keep your answers concise, practical, and conversational.\n"
        "If the user asks you to log, add, or record an expense or income (e.g. 'I spent 62 rupees on food'), "
        "you MUST respond ONLY with a JSON object in this exact format: "
        "{\"action\": \"add_transaction\", \"type\": \"expense\", \"amount\": 62, \"category\": \"Food\", \"notes\": \"\"} \n"
        "Set type to 'expense' or 'income'. Do NOT include any other text if you output this JSON.";

    if (contextData != null) {
      basePrompt += "\n\nThe user's current financial context from their local database is:\n\n$contextData\n\nUse this context to accurately answer the user's questions about their spending, budgets, and balances. Do NOT hallucinate data. If the user asks something not in the context, inform them gracefully.";
    }

    _chatHistory.add({
      "role": "user",
      "parts": [
        {"text": "System Instruction: $basePrompt\n\nUnderstood."}
      ]
    });
    
    _chatHistory.add({
      "role": "model",
      "parts": [
        {"text": "Understood. I will function as SpendX AI."}
      ]
    });
  }

  Future<String> sendMessage(String message) async {
    if (_chatHistory.isEmpty) {
      startChat(); 
    }

    _chatHistory.add({
      "role": "user", 
      "parts": [{"text": message}]
    });

    try {
      final response = await http.post(
        Uri.parse(_getApiUrl('gemini-2.5-flash')),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": _chatHistory,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final reply = data['candidates'][0]['content']['parts'][0]['text'] as String;
        
        _chatHistory.add({
          "role": "model", 
          "parts": [{"text": reply}]
        });
        
        return reply;
      } else {
        return 'API Error: ${response.statusCode} - ${response.body}';
      }
    } on SocketException {
      return 'Error: No internet connection. AI features require an active network.';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  Future<Map<String, String?>> scanReceipt(File imageFile) async {
    if (!_initialized) init();

    try {
      final bytes = await imageFile.readAsBytes();
      final base64Image = base64Encode(bytes);
      final mimeType = 'image/${imageFile.path.split('.').last.toLowerCase()}';
      
      const prompt = '''Analyze this receipt/bill image and extract:
1. Merchant/Store name
2. Total amount (numbers only, no currency symbol)  
3. Date (in YYYY-MM-DD format if visible)
4. Category (one of: Food, Shopping, Transport, Entertainment, Health, Utilities, Fuel, Other)

Respond ONLY as valid JSON like:
{"merchant": "...", "amount": "...", "date": "...", "category": "..."}

If a field is not visible, use null for its value.''';

      final response = await http.post(
        Uri.parse(_getApiUrl('gemini-2.5-flash')),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [
            {
              "parts": [
                {"text": prompt},
                {
                  "inlineData": {
                    "mimeType": mimeType == 'image/jpg' ? 'image/jpeg' : mimeType,
                    "data": base64Image
                  }
                }
              ]
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final replyText = data['candidates'][0]['content']['parts'][0]['text'] as String;
        
        final jsonStart = replyText.indexOf('{');
        final jsonEnd = replyText.lastIndexOf('}') + 1;
        if (jsonStart >= 0 && jsonEnd > jsonStart) {
          return _parseReceiptJson(replyText.substring(jsonStart, jsonEnd));
        }
        return {'error': 'Could not parse JSON from AI response'};
      }
      return {'error': 'API Error: ${response.statusCode} - ${response.body}'};
    } on SocketException {
      return {'error': 'No internet connection. AI features require an active network.'};
    } catch (e) {
      return {'error': 'Failed to process image with Gemini. ($e)'};
    }
  }

  Map<String, String?> _parseReceiptJson(String jsonStr) {
    final result = <String, String?>{};
    try {
      final Map<String, dynamic> parsed = jsonDecode(jsonStr);
      for (final field in ['merchant', 'amount', 'date', 'category']) {
        final val = parsed[field]?.toString().trim();
        result[field] = (val == null || val.isEmpty || val.toLowerCase() == 'null') ? null : val;
      }
    } catch (e) {
      debugPrint('Gemini JSON Parse Error: $e');
      for (final field in ['merchant', 'amount', 'date', 'category']) {
        final match = RegExp('"$field"\\s*:\\s*"?([^",}\\n]+)"?').firstMatch(jsonStr);
        if (match != null) {
          final val = match.group(1)?.trim().replaceAll('"', '').replaceAll('null', '');
          result[field] = (val == null || val.isEmpty) ? null : val;
        } else {
          result[field] = null;
        }
      }
    }
    return result;
  }

  Future<List<Map<String, String?>>> scanStatement(File file) async {
    if (!_initialized) init();

    try {
      final bytes = await file.readAsBytes();
      final base64Image = base64Encode(bytes);
      final mimeType = 'image/${file.path.split('.').last.toLowerCase()}';
      
      const prompt = '''Analyze this bank statement/document and extract ALL transactions.
Respond ONLY as a valid JSON array of objects, like:
[{"merchant": "...", "amount": "...", "date": "...", "category": "...", "type": "expense OR income"}]
If a field is not visible or applicable, use null for its value.
Do not wrap in markdown blocks or quotes. Just output raw JSON array.''';

      final response = await http.post(
        Uri.parse(_getApiUrl('gemini-2.5-flash')),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [
            {
              "parts": [
                {"text": prompt},
                {
                  "inlineData": {
                    "mimeType": mimeType == 'image/jpg' ? 'image/jpeg' : mimeType,
                    "data": base64Image
                  }
                }
              ]
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text = data['candidates'][0]['content']['parts'][0]['text'] as String;
        
        final jsonStart = text.indexOf('[');
        final jsonEnd = text.lastIndexOf(']') + 1;
        
        if (jsonStart >= 0 && jsonEnd > jsonStart) {
          try {
            final jList = jsonDecode(text.substring(jsonStart, jsonEnd)) as List;
            return jList.map((e) {
              final map = <String, String?>{};
              if(e is Map) {
                  e.forEach((k, v) => map[k.toString()] = v?.toString());
              }
              return map;
            }).toList();
          } catch(e) {
              debugPrint('Gemini Statement JSON Parse Error: $e');
              return [];
          }
        }
      }
      return [];
    } on SocketException {
      return [{'error': 'No internet connection. AI features require an active network.'}];
    } catch (e) {
      return [{'error': 'Failed to process document. ($e)'}];
    }
  }
}
