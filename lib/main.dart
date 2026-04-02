import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const PantryChefApp());
}

class PantryChefApp extends StatelessWidget {
  const PantryChefApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PantryChef',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE8A317),
          primary: const Color(0xFFC0451A),
          secondary: const Color(0xFFE8A317),
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}

// ─── Data Models ───────────────────────────────────────────────────────────────

class PantryItem {
  final String name;
  int quantity;
  String unit;
  PantryItem({required this.name, this.quantity = 1, this.unit = 'pcs'});
}

// ─── Groq Vision OCR ──────────────────────────────────────────────────────────

Future<List<String>> scanBillWithGroq(String apiKey, File imageFile) async {
  // Convert image to base64
  final bytes = await imageFile.readAsBytes();
  final base64Image = base64Encode(bytes);

  // Detect mime type
  final path = imageFile.path.toLowerCase();
  final mimeType = path.endsWith('.png') ? 'image/png' : 'image/jpeg';

  final response = await http.post(
    Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: jsonEncode({
      'model': 'meta-llama/llama-4-scout-17b-16e-instruct',
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:$mimeType;base64,$base64Image',
              },
            },
            {
              'type': 'text',
              'text': '''This is a grocery store receipt. Extract ONLY the food and grocery item names.
Rules:
- Ignore store name, address, phone number, date, time
- Ignore prices, totals, subtotals, taxes, HST, GST
- Ignore cashier name, transaction ID, loyalty points
- Ignore payment method (cash, visa, debit)
- Only include actual food/grocery product names
- Clean up OCR errors (e.g. "Cantal oupes" -> "Cantaloupes")
- Return ONLY a JSON array of strings, nothing else
Example: ["tomatoes", "milk", "bread", "paneer", "rice"]''',
            },
          ],
        }
      ],
      'max_tokens': 500,
    }),
  );

  debugPrint('Groq Vision status: ' + response.statusCode.toString());
  debugPrint('Groq Vision body: ' + response.body);

  if (response.statusCode != 200) {
    throw Exception('Groq Vision error: ' + response.statusCode.toString() + ' ' + response.body);
  }

  final data = jsonDecode(response.body);
  final text = (data['choices'][0]['message']['content'] as String)
      .replaceAll(RegExp(r'```json\s*'), '')
      .replaceAll(RegExp(r'```\s*'), '')
      .trim();

  debugPrint('Groq Vision items: ' + text);

  final List<dynamic> jsonList = jsonDecode(text);
  return jsonList.map((e) => e.toString().toLowerCase()).toList();
}

// ─── OCR Helper ────────────────────────────────────────────────────────────────

// ─── Universal Canadian Grocery Bill Parser ────────────────────────────────────

// Footer triggers - stop parsing when a line STARTS with these
const Set<String> _footerTriggers = {
  'subtotal','sub-total','total','balance due','amount due','owing',
  'approved','thank you','your total savings','your total',
  'number of items','tender','mastercard','visa','cash tendered',
  'debit','interac purchase','discounts & specials',
};

// Lines to always skip regardless of position
const Set<String> _skipLineKeywords = {
  'served by','cashier','operator','hst#','gst#','store#',
  'www.','http','@','loyalty','points','reward','member',
  'survey','receipt#','trans#','terminal','lane#',
};

// Store name keywords
const Set<String> _storeNames = {
  'freshco','fresh co','loblaws','nofrills','no frills','metro',
  'sobeys','walmart','costco','wholesale','iqbal','superstore',
  'real canadian','food basics','nations','farm boy','longos',
};

// Address/header patterns
final List<RegExp> _headerPatterns = [
  RegExp(r'\d{3}[\s\-]\d{3}[\s\-]\d{4}'),           // phone
  RegExp(r'(www\.|\.com|\.ca|\.org|@)'),              // web/email
  RegExp(r'[A-Z]\d[A-Z]\s?\d[A-Z]\d'),               // postal code
  RegExp(r'\b(ave|blvd|drive|lane|court|crescent|plaza|st\.)\b', caseSensitive: false),
  RegExp(r'\b(ontario|quebec|alberta|manitoba|scarboro|toronto|mississauga|brampton)\b', caseSensitive: false),
  RegExp(r'hst#|gst#', caseSensitive: false),         // tax numbers
  RegExp(r'\d{8,}'),                                  // long number sequences
];

// Words to remove from extracted item names
const Set<String> _cleanupWords = {
  'organic','fresh','natural','original','classic','regular','premium',
  'select','choice','value','great','best','extra','super','ultra',
  'large','medium','small','mini','family','bulk','party','assorted',
  'pkg','pack','bag','box','can','jar','bottle','tub','carton',
  'each','per','unit','units','piece','pieces','count',
};

// Lines that are clearly not food items
final List<RegExp> _nonFoodPatterns = [
  RegExp(r'^\d+\s*@\s*\d'),               // quantity lines like "2 @ 1/$2.99"
  RegExp(r'^\d+\.\d{3}\s*kg'),            // weight lines like "0.455 kg @ $3.95"
  RegExp(r'^\$[\d\.,]+'),                 // lines starting with price
  RegExp(r'^[\$\d\.\,\s]+C?$'),           // pure price lines like "$2.99 C"
  RegExp(r'\*{3,}'),                      // lines with ***
  RegExp(r'^[xX\*]+$'),                   // lines with xxx or ***
  RegExp(r'you saved', caseSensitive: false),
  RegExp(r'^\d+\s*$'),                    // pure number lines
];

bool _isStoreName(String line) {
  final lower = line.toLowerCase();
  // Also catch OCR variants where O is read as 0
  final normalized = lower.replaceAll('0', 'o');
  return _storeNames.any((s) => lower.contains(s) || normalized.contains(s));
}

bool _isAddressOrHeader(String line) {
  if (_headerPatterns.any((p) => p.hasMatch(line))) return true;
  final lower = line.toLowerCase();
  if (_skipLineKeywords.any((k) => lower.contains(k))) return true;
  return false;
}

bool _isFooterLine(String line) {
  final lower = line.toLowerCase().trim();
  return _footerTriggers.any((t) => lower.startsWith(t));
}

bool _isNonFoodLine(String line) {
  return _nonFoodPatterns.any((p) => p.hasMatch(line.trim()));
}

String _cleanItemName(String raw) {
  var cleaned = raw
      .replaceAll(RegExp(r'\d+\.\d{2}.*$'), '')        // remove price onwards
      .replaceAll(RegExp(r'^\s*\d+\s*[xX@]\s*'), '')   // remove "2 x" or "2@"
      .replaceAll(RegExp(r'\b\d+\s*(kg|lb|g|ml|l|oz)\b', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^a-zA-Z\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();

  final words = cleaned.split(' ').where((w) =>
  w.length > 2 && !_cleanupWords.contains(w)
  ).toList();

  return words.take(3).join(' ').trim();
}

List<String> parseGroceryItems(String ocrText) {
  final lines = ocrText.split('\n');
  final items = <String>[];

  // Debug output
  debugPrint('=== RAW OCR OUTPUT ===');
  for (var i = 0; i < lines.length; i++) {
    debugPrint('LINE $i: ${lines[i]}');
  }
  debugPrint('=== END RAW ===');

  // Step 1: Find where the header ends
  // Header = store name + address block at the top
  // We detect header end by finding the first line that looks like a real item:
  // - Not a store name, not an address, not a skip line
  // - Not a non-food pattern
  // - Has at least one real word (letters only, length > 2)
  int headerEndIdx = 0;

  // Scan first 10 lines as potential header regardless
  // Header always ends before actual items start
  for (var i = 0; i < lines.length && i < 10; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;

    final lower = line.toLowerCase();
    final normalized = lower.replaceAll('0', 'o');

    // Is this line part of the store header block?
    final isHeader = _isStoreName(line) ||
        _isAddressOrHeader(line) ||
        // Catch store address lines with store name embedded (like "GERRARD & VICTORIA PARK FRESHCO")
        _storeNames.any((s) => normalized.contains(s)) ||
        // Lines with street numbers at start (addresses)
        RegExp(r'^\d{2,5}\s+[A-Za-z]').hasMatch(line) ||
        // "Served by" type lines
        lower.startsWith('served') ||
        lower.startsWith('hst') ||
        lower.startsWith('gst');

    if (isHeader) {
      headerEndIdx = i + 1;
      debugPrint('HEADER[$i]: $line');
    }
  }

  debugPrint('Starting item scan from line $headerEndIdx');

  // Step 2: Scan item lines from headerEndIdx until footer
  for (var i = headerEndIdx; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;

    // Stop at footer
    if (_isFooterLine(line)) {
      debugPrint('FOOTER STOP[$i]: $line');
      break;
    }

    // Skip address/header looking lines
    if (_isAddressOrHeader(line)) {
      debugPrint('SKIP HEADER[$i]: $line');
      continue;
    }

    // Skip non-food patterns
    if (_isNonFoodLine(line)) {
      debugPrint('SKIP NON-FOOD[$i]: $line');
      continue;
    }

    // Extract item name
    final itemName = _cleanItemName(line);
    debugPrint('CANDIDATE[$i]: "$itemName" from "$line"');

    if (itemName.length > 2 && !items.contains(itemName)) {
      items.add(itemName);
      debugPrint('ADDED: $itemName');
    }
  }

  debugPrint('=== FINAL ITEMS: $items ===');
  return items;
}

// ─── Constants ─────────────────────────────────────────────────────────────────

const List<String> units = ['pcs','kg','g','L','ml','cup','tbsp','tsp','bunch','pack'];

// ─── Home Screen ───────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  List<PantryItem> inventory = [];

  @override
  void initState() {
    super.initState();
    _loadInventory();
  }

  // Load inventory from device storage
  Future<void> _loadInventory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> names = prefs.getStringList('inventory_names') ?? [];
    final List<String> quantities = prefs.getStringList('inventory_quantities') ?? [];
    final List<String> units = prefs.getStringList('inventory_units') ?? [];
    setState(() {
      inventory = List.generate(names.length, (i) => PantryItem(
        name: names[i],
        quantity: i < quantities.length ? int.tryParse(quantities[i]) ?? 1 : 1,
        unit: i < units.length ? units[i] : 'pcs',
      ));
    });
  }

  // Save inventory to device storage
  Future<void> _saveInventory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('inventory_names', inventory.map((i) => i.name).toList());
    await prefs.setStringList('inventory_quantities', inventory.map((i) => i.quantity.toString()).toList());
    await prefs.setStringList('inventory_units', inventory.map((i) => i.unit).toList());
  }

  void _addToInventory(List<String> items) {
    setState(() {
      for (final name in items) {
        final existing = inventory.where((i) => i.name == name.toLowerCase()).toList();
        if (existing.isEmpty) { inventory.add(PantryItem(name: name.toLowerCase())); }
        else { existing.first.quantity++; }
      }
    });
    _saveInventory();
  }

  void _removeFromInventory(String name) {
    setState(() => inventory.removeWhere((i) => i.name == name));
    _saveInventory();
  }

  void _addSingleItem(String name, int qty, String unit) {
    final trimmed = name.trim().toLowerCase();
    if (trimmed.isEmpty) return;
    setState(() {
      final existing = inventory.where((i) => i.name == trimmed).toList();
      if (existing.isEmpty) { inventory.add(PantryItem(name: trimmed, quantity: qty, unit: unit)); }
      else { existing.first.quantity += qty; }
    });
    _saveInventory();
  }

  void _updateItem(String name, int qty, String unit) {
    setState(() {
      final item = inventory.firstWhere((i) => i.name == name);
      item.quantity = qty;
      item.unit = unit;
    });
    _saveInventory();
  }

  // Deduct inventory based on recipe cooked
  void _deductInventory(Map<String, double> deductions) {
    setState(() {
      for (final entry in deductions.entries) {
        final itemName = entry.key.toLowerCase();
        final fraction = entry.value;
        final matches = inventory.where((i) =>
        i.name.contains(itemName) || itemName.contains(i.name)).toList();
        for (final item in matches) {
          final deductQty = (item.quantity * fraction).round();
          if (deductQty >= item.quantity) {
            inventory.remove(item);
          } else {
            item.quantity -= deductQty;
          }
          break;
        }
      }
    });
    _saveInventory();
  }

  @override
  Widget build(BuildContext context) {
    final pantryNames = inventory.map((i) => i.name).toList();
    final screens = [
      ScanScreen(onItemsAdded: _addToInventory),
      InventoryScreen(inventory: inventory, onRemove: _removeFromInventory, onAdd: _addSingleItem, onUpdate: _updateItem, onGoToRecipes: () => setState(() => _currentIndex = 2)),
      RecipesScreen(pantryNames: pantryNames, onDeductInventory: _deductInventory),
    ];
    return Scaffold(
      body: screens[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFFFDF3DC),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long, color: Color(0xFFC0451A)), label: 'Scan Bill'),
          NavigationDestination(icon: Icon(Icons.kitchen_outlined), selectedIcon: Icon(Icons.kitchen, color: Color(0xFFC0451A)), label: 'Inventory'),
          NavigationDestination(icon: Icon(Icons.restaurant_menu_outlined), selectedIcon: Icon(Icons.restaurant_menu, color: Color(0xFFC0451A)), label: 'Recipes'),
        ],
      ),
    );
  }
}

// ─── Scan Screen ───────────────────────────────────────────────────────────────

class ScanScreen extends StatefulWidget {
  final Function(List<String>) onItemsAdded;
  const ScanScreen({super.key, required this.onItemsAdded});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _isScanning = false;
  bool _scanned = false;
  List<String> _foundItems = [];
  final Set<int> _removedIndices = {};
  File? _imageFile;
  String _statusMessage = '';
  final ImagePicker _picker = ImagePicker();

  Future<void> _pickAndScan(ImageSource source) async {
    try {
      final XFile? picked = await _picker.pickImage(source: source, imageQuality: 85);
      if (picked == null) return;

      setState(() {
        _imageFile = File(picked.path);
        _isScanning = true;
        _scanned = false;
        _removedIndices.clear();
        _statusMessage = 'Reading bill with Groq Vision AI...';
      });

      // Load API key
      final prefs = await SharedPreferences.getInstance();
      final apiKey = prefs.getString('groq_api_key') ?? '';

      List<String> items = [];

      if (apiKey.isNotEmpty) {
        // Use Groq Vision for best accuracy
        items = await scanBillWithGroq(apiKey, _imageFile!);
        setState(() {
          _statusMessage = 'AI scanned successfully!';
        });
      } else {
        // Fallback to ML Kit if no API key
        setState(() { _statusMessage = 'No API key — using basic OCR. Add Groq key in Recipes > Settings for better results.'; });
        final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
        final inputImage = InputImage.fromFile(_imageFile!);
        final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
        await textRecognizer.close();
        final rawText = recognizedText.text;
        if (rawText.isEmpty) {
          setState(() { _isScanning = false; _statusMessage = 'No text found. Try a clearer photo.'; });
          return;
        }
        items = parseGroceryItems(rawText);
      }

      setState(() {
        _isScanning = false;
        _scanned = true;
        _foundItems = items;
        _statusMessage = items.isEmpty ? 'No items found. Try a clearer photo.' : '';
      });
    } catch (e) {
      debugPrint('Scan error: ' + e.toString());
      setState(() {
        _isScanning = false;
        _statusMessage = 'Error: ' + e.toString();
      });
    }
  }

  void _showSourcePicker() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Choose image source', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: _sourceButton(Icons.camera_alt, 'Camera', () { Navigator.pop(ctx); _pickAndScan(ImageSource.camera); })),
          const SizedBox(width: 12),
          Expanded(child: _sourceButton(Icons.photo_library, 'Gallery', () { Navigator.pop(ctx); _pickAndScan(ImageSource.gallery); })),
        ]),
      ]))),
    );
  }

  Widget _sourceButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(color: const Color(0xFFFDF3DC), borderRadius: BorderRadius.circular(12)),
        child: Column(children: [Icon(icon, size: 32, color: const Color(0xFFC0451A)), const SizedBox(height: 8), Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF4A1B0C)))])));
  }

  void _addToInventory() {
    final itemsToAdd = _foundItems.asMap().entries.where((e) => !_removedIndices.contains(e.key)).map((e) => e.value).toList();
    widget.onItemsAdded(itemsToAdd);
    setState(() { _scanned = false; _foundItems = []; _removedIndices.clear(); _imageFile = null; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added ${itemsToAdd.length} items to your pantry!'), backgroundColor: const Color(0xFF3B6D11), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F5),
      body: CustomScrollView(slivers: [
        SliverAppBar(expandedHeight: 120, pinned: true, backgroundColor: const Color(0xFFE8A317),
          flexibleSpace: FlexibleSpaceBar(
            title: const Text('PantryChef', style: TextStyle(color: Color(0xFF4A1B0C), fontWeight: FontWeight.w600, fontSize: 20)),
            background: Container(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFE8A317), Color(0xFFC0451A)]))),
          ),
        ),
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Scan Grocery Bill', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFF2C2C2A))),
          const SizedBox(height: 4),
          const Text('Take a photo or upload your grocery receipt', style: TextStyle(fontSize: 13, color: Color(0xFF5F5E5A))),
          const SizedBox(height: 16),
          GestureDetector(onTap: _isScanning ? null : _showSourcePicker, child: Container(width: double.infinity, height: _imageFile != null ? 220 : 160,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE8A317), width: 1.5)),
            child: _imageFile != null
                ? ClipRRect(borderRadius: BorderRadius.circular(15), child: Stack(fit: StackFit.expand, children: [
              Image.file(_imageFile!, fit: BoxFit.cover),
              if (_isScanning) Container(color: Colors.black45, child: const Center(child: CircularProgressIndicator(color: Colors.white))),
              Positioned(bottom: 8, right: 8, child: GestureDetector(onTap: _showSourcePicker, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.refresh, color: Colors.white, size: 14), SizedBox(width: 4), Text('Change', style: TextStyle(color: Colors.white, fontSize: 12))])))),
            ]))
                : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.add_a_photo, size: 48, color: Color(0xFFE8A317)),
              SizedBox(height: 12),
              Text('Tap to scan bill with Groq Vision AI', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Color(0xFF2C2C2A))),
              SizedBox(height: 4),
              Text('Camera or Gallery', style: TextStyle(fontSize: 12, color: Color(0xFF888780))),
            ]),
          )),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: _isScanning ? null : () => _pickAndScan(ImageSource.camera), icon: const Icon(Icons.camera_alt, size: 18), label: const Text('Camera'),
                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFC0451A), side: const BorderSide(color: Color(0xFFC0451A)), padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(onPressed: _isScanning ? null : () => _pickAndScan(ImageSource.gallery), icon: const Icon(Icons.photo_library, size: 18), label: const Text('Gallery'),
                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFC0451A), side: const BorderSide(color: Color(0xFFC0451A)), padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))))),
          ]),
          if (_statusMessage.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: _statusMessage.startsWith('Error') ? const Color(0xFFFCEBEB) : const Color(0xFFFDF3DC), borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  Icon(_statusMessage.startsWith('Error') ? Icons.error_outline : Icons.info_outline, size: 16, color: _statusMessage.startsWith('Error') ? const Color(0xFFE24B4A) : const Color(0xFF633806)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_statusMessage, style: TextStyle(fontSize: 13, color: _statusMessage.startsWith('Error') ? const Color(0xFF501313) : const Color(0xFF633806)))),
                ])),
          ],
          if (_scanned && _foundItems.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(children: [
              const Text('Items found', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF2C2C2A))),
              const SizedBox(width: 8),
              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: const Color(0xFFEAF3DE), borderRadius: BorderRadius.circular(100)),
                  child: Text('${_foundItems.length - _removedIndices.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF27500A)))),
              const Spacer(),
              const Text('Tap × to remove', style: TextStyle(fontSize: 11, color: Color(0xFF888780))),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: _foundItems.asMap().entries.map((entry) {
              final removed = _removedIndices.contains(entry.key);
              return AnimatedOpacity(opacity: removed ? 0.3 : 1.0, duration: const Duration(milliseconds: 200),
                  child: Chip(label: Text(entry.value), deleteIcon: const Icon(Icons.close, size: 14), onDeleted: removed ? null : () => setState(() => _removedIndices.add(entry.key)),
                      backgroundColor: const Color(0xFFFDF3DC), labelStyle: const TextStyle(fontSize: 13, color: Color(0xFF4A1B0C)), deleteIconColor: const Color(0xFF888780), side: BorderSide.none));
            }).toList()),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _addToInventory,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE8A317), foregroundColor: const Color(0xFF4A1B0C), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                child: const Text('Add all to inventory', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)))),
          ],
          if (_scanned && _foundItems.isEmpty) ...[
            const SizedBox(height: 16),
            Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFFFCEBEB), borderRadius: BorderRadius.circular(12)),
                child: const Column(children: [Icon(Icons.search_off, size: 32, color: Color(0xFFE24B4A)), SizedBox(height: 8), Text('No grocery items found', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF501313))), SizedBox(height: 4), Text('Try a clearer, well-lit photo of your bill', style: TextStyle(fontSize: 12, color: Color(0xFF791F1F)))])),
          ],
        ]))),
      ]),
    );
  }
}

// ─── Inventory Screen ──────────────────────────────────────────────────────────

class InventoryScreen extends StatefulWidget {
  final List<PantryItem> inventory;
  final Function(String) onRemove;
  final Function(String, int, String) onAdd;
  final Function(String, int, String) onUpdate;
  final VoidCallback onGoToRecipes;
  const InventoryScreen({super.key, required this.inventory, required this.onRemove, required this.onAdd, required this.onUpdate, required this.onGoToRecipes});
  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  final TextEditingController _nameController = TextEditingController();
  int _qty = 1;
  String _unit = 'pcs';

  @override
  void dispose() { _nameController.dispose(); super.dispose(); }

  void _showEditDialog(PantryItem item) {
    int editQty = item.quantity; String editUnit = item.unit;
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setDlgState) => AlertDialog(
      title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(onPressed: editQty > 1 ? () => setDlgState(() => editQty--) : null, icon: const Icon(Icons.remove_circle_outline), color: const Color(0xFFC0451A)),
          Container(width: 56, alignment: Alignment.center, child: Text('$editQty', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600))),
          IconButton(onPressed: () => setDlgState(() => editQty++), icon: const Icon(Icons.add_circle_outline), color: const Color(0xFFC0451A)),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(value: editUnit, decoration: InputDecoration(labelText: 'Unit', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            items: units.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(), onChanged: (val) => setDlgState(() => editUnit = val!)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () { widget.onUpdate(item.name, editQty, editUnit); Navigator.pop(ctx); }, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC0451A), foregroundColor: Colors.white), child: const Text('Save')),
      ],
    )));
  }

  void _showAddDialog() {
    _nameController.clear(); _qty = 1; _unit = 'pcs';
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setDlgState) => AlertDialog(
      title: const Text('Add Item', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _nameController, autofocus: true, decoration: InputDecoration(labelText: 'Item name', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10))),
        const SizedBox(height: 12),
        Row(children: [
          IconButton(onPressed: _qty > 1 ? () => setDlgState(() => _qty--) : null, icon: const Icon(Icons.remove_circle_outline), color: const Color(0xFFC0451A)),
          Container(width: 40, alignment: Alignment.center, child: Text('$_qty', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
          IconButton(onPressed: () => setDlgState(() => _qty++), icon: const Icon(Icons.add_circle_outline), color: const Color(0xFFC0451A)),
          const SizedBox(width: 8),
          Expanded(child: DropdownButtonFormField<String>(value: _unit, decoration: InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              items: units.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(), onChanged: (val) => setDlgState(() => _unit = val!))),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () { widget.onAdd(_nameController.text, _qty, _unit); Navigator.pop(ctx); }, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC0451A), foregroundColor: Colors.white), child: const Text('Add')),
      ],
    )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F5),
      appBar: AppBar(title: const Text('My Pantry', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2C2C2A))), backgroundColor: const Color(0xFFFAF8F5), elevation: 0,
          actions: [Padding(padding: const EdgeInsets.only(right: 16), child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: const Color(0xFFEAF3DE), borderRadius: BorderRadius.circular(100)),
              child: Text('${widget.inventory.length} items', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF27500A))))))]),
      floatingActionButton: FloatingActionButton(onPressed: _showAddDialog, backgroundColor: const Color(0xFFC0451A), foregroundColor: Colors.white, child: const Icon(Icons.add)),
      body: widget.inventory.isEmpty
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.kitchen_outlined, size: 64, color: Color(0xFFD3D1C7)), SizedBox(height: 16), Text('Your pantry is empty', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF888780))), SizedBox(height: 8), Text('Scan a grocery bill to get started!', style: TextStyle(fontSize: 13, color: Color(0xFFB4B2A9)))]))
          : Column(children: [
        Expanded(child: ListView.separated(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), itemCount: widget.inventory.length, separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final item = widget.inventory[index];
            return Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFD3D1C7), width: 0.5)),
                child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFFFDF3DC), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.set_meal, color: Color(0xFFE8A317), size: 22)),
                  title: Text(item.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF2C2C2A))),
                  subtitle: Text('${item.quantity} ${item.unit}', style: const TextStyle(fontSize: 13, color: Color(0xFF888780))),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    GestureDetector(onTap: () { if (item.quantity > 1) widget.onUpdate(item.name, item.quantity - 1, item.unit); }, child: Container(width: 28, height: 28, decoration: BoxDecoration(color: const Color(0xFFF1EFE8), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.remove, size: 14, color: Color(0xFF5F5E5A)))),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('${item.quantity}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF2C2C2A)))),
                    GestureDetector(onTap: () => widget.onUpdate(item.name, item.quantity + 1, item.unit), child: Container(width: 28, height: 28, decoration: BoxDecoration(color: const Color(0xFFFDF3DC), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.add, size: 14, color: Color(0xFFC0451A)))),
                    const SizedBox(width: 8),
                    GestureDetector(onTap: () => _showEditDialog(item), child: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF888780))),
                    const SizedBox(width: 8),
                    GestureDetector(onTap: () => widget.onRemove(item.name), child: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFE24B4A))),
                  ]),
                ));
          },
        )),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: SizedBox(width: double.infinity, child: ElevatedButton(onPressed: widget.onGoToRecipes,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC0451A), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Suggest recipes from pantry', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600))))),
      ]),
    );
  }
}

// ─── Recipes Screen ────────────────────────────────────────────────────────────

// ─── Groq API Helper ──────────────────────────────────────────────────────────

class GroqRecipe {
  final String name;
  final String description;
  final String difficulty;
  final String time;
  final int timeMinutes;
  final List<String> ingredients;
  final String youtubeSearch;
  final int proteinG;
  final int carbsG;

  GroqRecipe({
    required this.name,
    required this.description,
    required this.difficulty,
    required this.time,
    required this.timeMinutes,
    required this.ingredients,
    required this.youtubeSearch,
    required this.proteinG,
    required this.carbsG,
  });

  factory GroqRecipe.fromJson(Map<String, dynamic> json) {
    return GroqRecipe(
      name: json['name'] ?? '',
      description: json['description'] ?? '',
      difficulty: json['difficulty'] ?? 'Medium',
      time: json['time'] ?? '30 mins',
      timeMinutes: json['timeMinutes'] ?? 30,
      ingredients: List<String>.from(json['ingredients'] ?? []),
      youtubeSearch: json['youtubeSearch'] ?? '',
      proteinG: json['proteinG'] ?? 0,
      carbsG: json['carbsG'] ?? 0,
    );
  }
}

Future<List<GroqRecipe>> fetchGroqRecipes(String apiKey, List<String> pantryItems) async {
  final prompt = '''
You are an expert Indian vegetarian chef. Based on these ingredients: ${pantryItems.join(', ')},
suggest 5 Indian vegetarian eggless recipes that can be made.

Respond ONLY with a valid JSON array. No explanation, no markdown, no extra text.
Each recipe must have exactly these fields:
[
  {
    "name": "Recipe Name",
    "description": "2 sentence description",
    "difficulty": "Easy",
    "time": "25 mins",
    "timeMinutes": 25,
    "ingredients": ["ingredient1", "ingredient2"],
    "youtubeSearch": "recipe name recipe authentic indian",
    "proteinG": 12,
    "carbsG": 45
  }
]
Rules:
- difficulty must be exactly one of: Easy, Medium, Hard
- timeMinutes must be an integer (total cook + prep time in minutes)
- proteinG is approximate protein per serving in grams (integer)
- carbsG is approximate carbohydrates per serving in grams (integer)
''';

  final response = await http.post(
    Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: jsonEncode({
      'model': 'llama-3.3-70b-versatile',
      'messages': [
        {'role': 'user', 'content': prompt}
      ],
      'temperature': 0.7,
      'max_tokens': 1500,
    }),
  );

  debugPrint('Groq status: ' + response.statusCode.toString());
  debugPrint('Groq body: ' + response.body);

  if (response.statusCode != 200) {
    throw Exception('Groq API error: \${response.statusCode} \${response.body}');
  }

  final data = jsonDecode(response.body);
  final text = data['choices'][0]['message']['content'] as String;
  debugPrint('Groq content: ' + text);

  // Clean the response - remove markdown if present
  final cleaned = text
      .replaceAll(RegExp(r'```json\s*'), '')
      .replaceAll(RegExp(r'```\s*'), '')
      .trim();

  debugPrint('Cleaned: ' + cleaned);

  final List<dynamic> jsonList = jsonDecode(cleaned);
  return jsonList.map((j) => GroqRecipe.fromJson(j)).toList();
}

// Search recipes by keyword
Future<List<GroqRecipe>> searchGroqRecipes(String apiKey, String keyword, List<String> pantryItems) async {
  final pantryContext = pantryItems.isNotEmpty
      ? 'I have these ingredients available: \${pantryItems.join(", ")}.'
      : '';

  final prompt = '''
You are an expert Indian vegetarian chef. \$pantryContext
Suggest 5 Indian vegetarian eggless recipes related to: "\$keyword"

Respond ONLY with a valid JSON array. No explanation, no markdown, no extra text.
Each recipe must have exactly these fields:
[
  {
    "name": "Recipe Name",
    "description": "2 sentence description",
    "difficulty": "Easy",
    "time": "25 mins",
    "timeMinutes": 25,
    "ingredients": ["ingredient1", "ingredient2"],
    "youtubeSearch": "recipe name recipe authentic indian",
    "proteinG": 12,
    "carbsG": 45
  }
]
Rules:
- difficulty must be exactly one of: Easy, Medium, Hard
- timeMinutes must be an integer
- proteinG is approximate protein per serving in grams (integer)
- carbsG is approximate carbohydrates per serving in grams (integer)
''';

  final response = await http.post(
    Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer \$apiKey',
    },
    body: jsonEncode({
      'model': 'llama-3.3-70b-versatile',
      'messages': [{'role': 'user', 'content': prompt}],
      'temperature': 0.7,
      'max_tokens': 1500,
    }),
  );

  if (response.statusCode != 200) {
    throw Exception('Groq search error: ' + response.statusCode.toString());
  }

  final data = jsonDecode(response.body);
  final text = (data['choices'][0]['message']['content'] as String)
      .replaceAll(RegExp(r'```json\s*'), '')
      .replaceAll(RegExp(r'```\s*'), '')
      .trim();

  final List<dynamic> jsonList = jsonDecode(text);
  return jsonList.map((j) => GroqRecipe.fromJson(j)).toList();
}

// Deduce inventory based on recipe cooked
Future<Map<String, double>> deduceInventoryWithGroq(String apiKey, String recipeName, int servings, List<String> pantryItems) async {
  final prompt = '''
A user cooked "\$recipeName" for \$servings people.
Their current pantry: \${pantryItems.join(", ")}.

Based on typical quantities needed for this recipe for \$servings servings,
estimate how much of each pantry item was used.

Respond ONLY with a valid JSON object where keys are pantry item names (exactly as given)
and values are the fraction used (0.0 to 1.0). Only include items that were actually used.
Example: {"tomatoes": 0.5, "onions": 0.3, "paneer": 1.0}

No explanation, no markdown, just the JSON object.
''';

  final response = await http.post(
    Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer \$apiKey',
    },
    body: jsonEncode({
      'model': 'llama-3.3-70b-versatile',
      'messages': [{'role': 'user', 'content': prompt}],
      'temperature': 0.3,
      'max_tokens': 500,
    }),
  );

  if (response.statusCode != 200) {
    throw Exception('Groq deduction error: ' + response.statusCode.toString());
  }

  final data = jsonDecode(response.body);
  final text = (data['choices'][0]['message']['content'] as String)
      .replaceAll(RegExp(r'```json\s*'), '')
      .replaceAll(RegExp(r'```\s*'), '')
      .trim();

  debugPrint('Deduction result: ' + text);

  final Map<String, dynamic> raw = jsonDecode(text);
  return raw.map((k, v) => MapEntry(k, (v as num).toDouble()));
}

// ─── Recipes Screen ────────────────────────────────────────────────────────────

class RecipesScreen extends StatefulWidget {
  final List<String> pantryNames;
  final Function(Map<String, double>) onDeductInventory;
  const RecipesScreen({super.key, required this.pantryNames, required this.onDeductInventory});

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

enum SortOption { time, protein, carbs }
enum RecipeMode { pantry, search }

class _RecipesScreenState extends State<RecipesScreen> {
  List<GroqRecipe> _groqRecipes = [];
  bool _isLoading = false;
  String _error = '';
  String _apiKey = '';
  bool _hasKey = false;
  SortOption _sortOption = SortOption.time;
  RecipeMode _mode = RecipeMode.pantry;
  final TextEditingController _searchController = TextEditingController();
  String _lastSearch = '';

  @override
  void initState() {
    super.initState();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = (prefs.getString('groq_api_key') ?? '').trim();
    setState(() {
      _apiKey = key;
      _hasKey = key.isNotEmpty;
    });
    if (_hasKey && widget.pantryNames.isNotEmpty) {
      _fetchRecipes();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchRecipes() async {
    if (widget.pantryNames.isEmpty) return;
    // Reload key fresh from storage every time
    final prefs = await SharedPreferences.getInstance();
    final freshKey = (prefs.getString('groq_api_key') ?? '').trim();
    if (freshKey.isEmpty) {
      setState(() { _hasKey = false; });
      return;
    }
    setState(() { _isLoading = true; _error = ''; _mode = RecipeMode.pantry; _apiKey = freshKey; });
    try {
      final recipes = await fetchGroqRecipes(freshKey, widget.pantryNames);
      setState(() { _groqRecipes = recipes; _isLoading = false; });
    } catch (e) {
      debugPrint('Groq error: ' + e.toString());
      setState(() {
        _isLoading = false;
        _error = e.toString().contains('401')
            ? 'Invalid API key. Please check your Groq API key in Settings.'
            : e.toString().contains('SocketException') || e.toString().contains('HandshakeException')
            ? 'No internet connection. Please check your WiFi or mobile data.'
            : 'Error: ' + e.toString();
      });
    }
  }

  Future<void> _searchRecipes(String keyword) async {
    if (keyword.trim().isEmpty) return;
    // Reload key fresh from storage every time
    final prefs = await SharedPreferences.getInstance();
    final freshKey = (prefs.getString('groq_api_key') ?? '').trim();
    if (freshKey.isEmpty) {
      setState(() { _error = 'No API key found. Please add your Groq key in Settings.'; });
      return;
    }
    _lastSearch = keyword.trim();
    FocusScope.of(context).unfocus();
    setState(() { _isLoading = true; _error = ''; _mode = RecipeMode.search; });
    try {
      final recipes = await searchGroqRecipes(freshKey, keyword, widget.pantryNames);
      setState(() { _groqRecipes = recipes; _isLoading = false; });
    } catch (e) {
      debugPrint('Search error: ' + e.toString());
      setState(() {
        _isLoading = false;
        _error = 'Search failed: ' + e.toString();
      });
    }
  }

  List<GroqRecipe> get _sortedRecipes {
    final sorted = List<GroqRecipe>.from(_groqRecipes);
    switch (_sortOption) {
      case SortOption.time:
        sorted.sort((a, b) => a.timeMinutes.compareTo(b.timeMinutes));
        break;
      case SortOption.protein:
        sorted.sort((a, b) => b.proteinG.compareTo(a.proteinG));
        break;
      case SortOption.carbs:
        sorted.sort((a, b) => a.carbsG.compareTo(b.carbsG));
        break;
    }
    return sorted;
  }

  Color _dc(String d) => d == 'Easy' ? const Color(0xFF3B6D11) : d == 'Medium' ? const Color(0xFFBA7517) : const Color(0xFF993C1D);
  Color _db(String d) => d == 'Easy' ? const Color(0xFFEAF3DE) : d == 'Medium' ? const Color(0xFFFAEEDA) : const Color(0xFFFAECE7);

  Widget _badge(String label, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(100)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: fg)));

  Widget _sortChip(String label, SortOption option, IconData icon) {
    final selected = _sortOption == option;
    return GestureDetector(
      onTap: () => setState(() => _sortOption = option),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFC0451A) : Colors.white,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: selected ? const Color(0xFFC0451A) : const Color(0xFFD3D1C7),
            width: selected ? 1.5 : 0.5,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: selected ? Colors.white : const Color(0xFF5F5E5A)),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
              color: selected ? Colors.white : const Color(0xFF5F5E5A))),
        ]),
      ),
    );
  }

  void _showDeductDialog(BuildContext context, String recipeName) {
    int servings = 2;
    bool isLoading = false;
    String status = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.kitchen, color: Color(0xFFE8A317), size: 22),
              const SizedBox(width: 8),
              const Text('Update Inventory', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 4),
            Text('I cooked: $recipeName', style: const TextStyle(fontSize: 13, color: Color(0xFF5F5E5A))),
            const SizedBox(height: 16),
            const Text('How many people did you cook for?', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                onPressed: servings > 1 ? () => setSheetState(() => servings--) : null,
                icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFC0451A), size: 28),
              ),
              Container(
                width: 60, alignment: Alignment.center,
                child: Text('$servings', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                onPressed: () => setSheetState(() => servings++),
                icon: const Icon(Icons.add_circle_outline, color: Color(0xFFC0451A), size: 28),
              ),
              const Text('people', style: TextStyle(fontSize: 14, color: Color(0xFF888780))),
            ]),
            const SizedBox(height: 16),
            if (status.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: status.startsWith('Error') ? const Color(0xFFFCEBEB) : const Color(0xFFEAF3DE),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(status, style: TextStyle(fontSize: 12,
                    color: status.startsWith('Error') ? const Color(0xFF501313) : const Color(0xFF27500A))),
              ),
            SizedBox(width: double.infinity, child: ElevatedButton(
              onPressed: isLoading ? null : () async {
                setSheetState(() { isLoading = true; status = 'Calculating ingredients used...'; });
                try {
                  // Reload key fresh in case it wasn't loaded
                  final prefs = await SharedPreferences.getInstance();
                  final freshKey = (prefs.getString('groq_api_key') ?? _apiKey).trim();
                  debugPrint('Deduction key length: ' + freshKey.length.toString());
                  debugPrint('Deduction key starts with: ' + (freshKey.length > 6 ? freshKey.substring(0, 6) : freshKey));
                  if (freshKey.isEmpty) throw Exception('No API key found. Please add your Groq key in Settings.');
                  if (!freshKey.startsWith('gsk_')) throw Exception('Invalid API key format. Key should start with gsk_');
                  final deductions = await deduceInventoryWithGroq(freshKey, recipeName, servings, widget.pantryNames);
                  widget.onDeductInventory(deductions);
                  setSheetState(() {
                    isLoading = false;
                    status = 'Inventory updated! Removed ingredients used for $servings servings.';
                  });
                  await Future.delayed(const Duration(seconds: 2));
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  setSheetState(() { isLoading = false; status = 'Error: ' + e.toString(); });
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC0451A), foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: isLoading
                  ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Updating inventory...'),
              ])
                  : const Text('I cooked this! Update inventory', style: TextStyle(fontWeight: FontWeight.w600)),
            )),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F5),
      appBar: AppBar(
        title: const Text('Recipe Suggestions', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2C2C2A))),
        backgroundColor: const Color(0xFFFAF8F5), elevation: 0,
        actions: [
          if (_hasKey && widget.pantryNames.isNotEmpty && !_isLoading)
            IconButton(icon: const Icon(Icons.refresh, color: Color(0xFFC0451A)), onPressed: _fetchRecipes, tooltip: 'Refresh from pantry'),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Color(0xFF5F5E5A)),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
              _loadApiKey();
            },
          ),
        ],
      ),
      body: !_hasKey
          ? _buildNoKeyScreen(context)
          : widget.pantryNames.isEmpty
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.restaurant_menu_outlined, size: 64, color: Color(0xFFD3D1C7)),
        SizedBox(height: 16),
        Text('No recipes yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF888780))),
        SizedBox(height: 8),
        Text('Add items to your pantry first!', style: TextStyle(fontSize: 13, color: Color(0xFFB4B2A9))),
      ]))
          : _isLoading
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        CircularProgressIndicator(color: Color(0xFFC0451A)),
        SizedBox(height: 16),
        Text('Asking Llama 4 for recipe ideas...', style: TextStyle(fontSize: 14, color: Color(0xFF888780))),
        SizedBox(height: 8),
        Text('This takes a few seconds', style: TextStyle(fontSize: 12, color: Color(0xFFB4B2A9))),
      ]))
          : _error.isNotEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.error_outline, size: 48, color: Color(0xFFE24B4A)),
        const SizedBox(height: 16),
        Text(_error, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF5F5E5A))),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: _fetchRecipes,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC0451A), foregroundColor: Colors.white),
            child: const Text('Try Again')),
      ])))
          : _groqRecipes.isEmpty
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.restaurant_menu_outlined, size: 64, color: Color(0xFFD3D1C7)),
        const SizedBox(height: 16),
        const Text('No recipes found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF888780))),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: _fetchRecipes,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC0451A), foregroundColor: Colors.white),
            child: const Text('Try Again')),
      ]))
          : Column(children: [
        // Search bar
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(children: [
            Expanded(child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search recipes (e.g. "paneer", "quick breakfast")...',
                hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFB4B2A9)),
                prefixIcon: const Icon(Icons.search, size: 20, color: Color(0xFF888780)),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.close, size: 18, color: Color(0xFF888780)),
                    onPressed: () { _searchController.clear(); setState(() {}); })
                    : null,
                filled: true,
                fillColor: const Color(0xFFF1EFE8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: (v) => setState(() {}),
              onSubmitted: _searchRecipes,
            )),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _isLoading ? null : () => _searchRecipes(_searchController.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC0451A), foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: const Text('Go', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
        // Mode indicator
        if (_mode == RecipeMode.search && _lastSearch.isNotEmpty)
          Container(
            color: const Color(0xFFFDF3DC),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              const Icon(Icons.search, size: 14, color: Color(0xFF633806)),
              const SizedBox(width: 6),
              Expanded(child: Text('Results for: "$_lastSearch"', style: const TextStyle(fontSize: 12, color: Color(0xFF633806)))),
              GestureDetector(
                onTap: () { _searchController.clear(); _fetchRecipes(); },
                child: const Text('Back to pantry', style: TextStyle(fontSize: 12, color: Color(0xFFC0451A), fontWeight: FontWeight.w500)),
              ),
            ]),
          ),
        // Sort bar
        Container(
          color: const Color(0xFFFAF8F5),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            const Text('Sort by:', style: TextStyle(fontSize: 12, color: Color(0xFF888780))),
            const SizedBox(width: 8),
            _sortChip('Time', SortOption.time, Icons.timer_outlined),
            const SizedBox(width: 6),
            _sortChip('Protein', SortOption.protein, Icons.fitness_center),
            const SizedBox(width: 6),
            _sortChip('Carbs', SortOption.carbs, Icons.grain),
          ]),
        ),
        const Divider(height: 1, color: Color(0xFFD3D1C7)),
        // Recipe list
        Expanded(child: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: _sortedRecipes.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final r = _sortedRecipes[index];
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF9FE1CB), width: 1.5),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(r.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF2C2C2A)))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFEAF3DE), borderRadius: BorderRadius.circular(100)),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.auto_awesome, size: 10, color: Color(0xFF27500A)),
                      SizedBox(width: 3),
                      Text('AI pick', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF27500A))),
                    ]),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(r.description, style: const TextStyle(fontSize: 13, color: Color(0xFF5F5E5A), height: 1.5)),
                const SizedBox(height: 10),
                // Badges row
                Wrap(spacing: 6, runSpacing: 6, children: [
                  _badge(r.difficulty, _db(r.difficulty), _dc(r.difficulty)),
                  _badge(r.time, const Color(0xFFFDF3DC), const Color(0xFF633806)),
                  _badge('Veg • Eggless', const Color(0xFFEAF3DE), const Color(0xFF27500A)),
                ]),
                const SizedBox(height: 8),
                // Nutrition row
                Row(children: [
                  _nutritionChip(Icons.fitness_center, r.proteinG.toString() + 'g protein', const Color(0xFFE6F1FB), const Color(0xFF0C447C)),
                  const SizedBox(width: 6),
                  _nutritionChip(Icons.grain, r.carbsG.toString() + 'g carbs', const Color(0xFFFAECE7), const Color(0xFF993C1D)),
                ]),
                const SizedBox(height: 10),
                Wrap(children: [
                  const Text('Ingredients: ', style: TextStyle(fontSize: 12, color: Color(0xFF888780))),
                  Text(r.ingredients.join(', '), style: const TextStyle(fontSize: 12, color: Color(0xFF3B6D11), fontWeight: FontWeight.w500)),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  GestureDetector(
                    onTap: () async {
                      final url = Uri.parse('https://www.youtube.com/results?search_query=' + Uri.encodeComponent(r.youtubeSearch));
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url, mode: LaunchMode.externalApplication);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(color: const Color(0xFFFF0000), borderRadius: BorderRadius.circular(8)),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.play_circle_filled, color: Colors.white, size: 16),
                        SizedBox(width: 6),
                        Text('Watch on YouTube', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _showDeductDialog(context, r.name),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF3DE),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF9FE1CB)),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.check_circle_outline, color: Color(0xFF3B6D11), size: 16),
                        SizedBox(width: 6),
                        Text('I cooked this', style: TextStyle(color: Color(0xFF3B6D11), fontSize: 13, fontWeight: FontWeight.w500)),
                      ]),
                    ),
                  ),
                ]),
              ]),
            );
          },
        )),
      ]),
    );
  }

  Widget _nutritionChip(IconData icon, String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(100)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: fg),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: fg)),
      ]),
    );
  }

  Widget _buildNoKeyScreen(BuildContext context) {
    return Center(child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 80, height: 80,
            decoration: BoxDecoration(color: const Color(0xFFFDF3DC), borderRadius: BorderRadius.circular(20)),
            child: const Icon(Icons.key, size: 40, color: Color(0xFFE8A317))),
        const SizedBox(height: 20),
        const Text('Add your Groq API Key', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFF2C2C2A))),
        const SizedBox(height: 8),
        const Text('Get a free API key from console.groq.com to enable AI-powered recipe suggestions using Llama 4.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Color(0xFF5F5E5A), height: 1.5)),
        const SizedBox(height: 24),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
            _loadApiKey();
          },
          icon: const Icon(Icons.settings),
          label: const Text('Enter API Key'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFC0451A), foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        )),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          onPressed: () async {
            final url = Uri.parse('https://console.groq.com');
            if (await canLaunchUrl(url)) await launchUrl(url, mode: LaunchMode.externalApplication);
          },
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('Get free key at console.groq.com'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFC0451A),
            side: const BorderSide(color: Color(0xFFC0451A)),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        )),
      ]),
    ));
  }
}

// ─── Settings Screen ───────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _keyController = TextEditingController();
  bool _obscure = true;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  Future<void> _loadKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('groq_api_key') ?? '';
    setState(() => _keyController.text = key);
  }

  Future<void> _saveKey() async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = _keyController.text.trim();
    if (!trimmed.startsWith('gsk_')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Key should start with gsk_ — please check and try again'),
        backgroundColor: Color(0xFFE24B4A),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    await prefs.setString('groq_api_key', trimmed);
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  Future<void> _clearKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('groq_api_key');
    setState(() => _keyController.text = '');
  }

  @override
  void dispose() { _keyController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F5),
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2C2C2A))),
        backgroundColor: const Color(0xFFFAF8F5), elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Groq API Key section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFD3D1C7), width: 0.5),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.key, size: 18, color: Color(0xFFE8A317)),
                SizedBox(width: 8),
                Text('Groq API Key', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF2C2C2A))),
              ]),
              const SizedBox(height: 4),
              const Text('Get your free key at console.groq.com', style: TextStyle(fontSize: 12, color: Color(0xFF888780))),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  hintText: 'gsk_...',
                  hintStyle: const TextStyle(color: Color(0xFFB4B2A9)),
                  filled: true,
                  fillColor: const Color(0xFFF1EFE8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18, color: const Color(0xFF888780)),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: ElevatedButton(
                  onPressed: _saveKey,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _saved ? const Color(0xFF3B6D11) : const Color(0xFFC0451A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(_saved ? 'Saved!' : 'Save Key', style: const TextStyle(fontWeight: FontWeight.w600)),
                )),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: _clearKey,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE24B4A),
                    side: const BorderSide(color: Color(0xFFE24B4A)),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Clear'),
                ),
              ]),
            ]),
          ),

          const SizedBox(height: 16),

          // Info box
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFFFDF3DC), borderRadius: BorderRadius.circular(12)),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.info_outline, size: 16, color: Color(0xFF633806)),
                SizedBox(width: 6),
                Text('About Groq', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF633806))),
              ]),
              SizedBox(height: 6),
              Text('Groq is free to use with generous limits (14,400 requests/day). Your API key is stored only on your device and never shared.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF633806), height: 1.5)),
            ]),
          ),
        ]),
      ),
    );
  }
}