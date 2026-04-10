class CategoryClassifier {
  static final Map<String, List<String>> expenseRules = {
    'Food': [
      'zomato', 'swiggy', 'restaurant', 'cafe', 'eat', 'food', 'dine',
      'pizza', 'burger', 'dominos', 'mcdonalds', 'kfc', 'subway',
      'biryani', 'kitchen', 'canteen', 'mess', 'dhaba', 'bakery',
      'blinkit', 'zepto', 'instamart',
    ],
    'Transport': [
      'uber', 'ola', 'fuel', 'petrol', 'diesel', 'bus', 'train',
      'metro', 'rapido', 'auto', 'cab', 'taxi', 'irctc', 'redbus',
      'toll', 'fastag', 'parking', 'nhai',
    ],
    'Groceries': [
      'supermarket', 'mart', 'grocery', 'store', 'bigbasket', 'dmart',
      'reliance', 'more', 'spencers', 'nature basket', 'jiomart',
      'vegetables', 'fruits', 'provision', 'kirana',
    ],
    'Bills': [
      'electricity', 'water', 'bill', 'recharge', 'postpaid', 'prepaid',
      'mobile', 'broadband', 'internet', 'gas', 'cylinder', 'piped gas',
      'dth', 'tata sky', 'airtel', 'jio', 'vi ', 'bsnl',
      'electricity board', 'bescom', 'mseb', 'kseb', 'tneb',
    ],
    'Shopping': [
      'amazon', 'flipkart', 'myntra', 'ajio', 'meesho', 'nykaa',
      'tata cliq', 'snapdeal', 'shopping', 'purchase', 'online',
      'croma', 'reliance digital', 'vijay sales',
    ],
    'Subscriptions': [
      'netflix', 'spotify', 'prime', 'hotstar', 'disney', 'youtube',
      'apple', 'google play', 'icloud', 'amazon prime', 'zee5',
      'sonyliv', 'jiocinema', 'subscription', 'renewal', 'membership',
    ],
    'Health': [
      'hospital', 'pharmacy', 'clinic', 'doctor', 'medical', 'medicine',
      'apollo', 'medplus', 'netmeds', 'pharmeasy', '1mg', 'tata health',
      'lab test', 'diagnostic', 'dental', 'optical',
    ],
    'Travel': [
      'flight', 'hotel', 'booking', 'makemytrip', 'goibibo', 'cleartrip',
      'yatra', 'oyo', 'airbnb', 'indigo', 'spicejet', 'vistara',
      'air india', 'ixigo', 'easemytrip', 'resort',
    ],
    'Education': [
      'school', 'college', 'university', 'tuition', 'course', 'class',
      'udemy', 'coursera', 'unacademy', 'byju', 'vedantu', 'exam',
      'book', 'stationery',
    ],
    'Entertainment': [
      'movie', 'cinema', 'pvr', 'inox', 'bookmyshow', 'event', 'ticket',
      'gaming', 'play store', 'app store', 'game',
    ],
    'Insurance': [
      'insurance', 'premium', 'lic', 'policy', 'health insurance',
      'term plan', 'cover', 'icici lombard', 'hdfc ergo',
      'star health', 'max bupa',
    ],
    'EMI': [
      'emi', 'installment', 'equated monthly', 'loan emi', 'auto debit',
    ],
    'Rent': [
      'rent', 'house rent', 'flat rent', 'pg', 'hostel', 'landlord',
      'maintenance', 'society',
    ],
  };

  static final Map<String, List<String>> incomeRules = {
    'Salary': [
      'salary', 'payroll', 'credited by', 'monthly salary', 'pay credit',
      'wage', 'stipend', 'compensation',
    ],
    'Freelance': ['client payment', 'project', 'invoice', 'consulting'],
    'Investment': [
      'dividend', 'interest', 'mutual fund', 'fd maturity',
      'fixed deposit', 'returns', 'capital gain',
    ],
    'Refund': ['refund', 'reversal', 'cashback', 'return amount'],
    'Other Income': [
      'received', 'credit', 'transfer from', 'gift', 'reward',
    ],
  };

  static String? detect({required String text, required String type}) {
    final lower = text.toLowerCase();
    final rules = type == 'income' ? incomeRules : expenseRules;

    for (final entry in rules.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) {
          return entry.key;
        }
      }
    }

    return null;
  }
}
