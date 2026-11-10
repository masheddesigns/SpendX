package com.mashingdesigns.spend_x

import java.util.regex.Pattern

/**
 * High-precision filter to ensure only genuine financial messages (debits,
 * credits, payments, bank/card balance statements) are processed by SpendX.
 *
 * Drops OTPs, PIN resets, telecom recharges, weather alerts, delivery tracking,
 * promotional offers, and personal text messages.
 */
object FinancialSmsFilter {
    // 1. Explicit OTP / Auth / Security rejection
    private val OTP_AUTH_REGEX = Pattern.compile(
        """\b(?:otp|one[- ]time password|verification code|security code|secret code|login code|passcode|auth code|pin reset|reset.*pin|cvv)\b|""" +
        """\b(?:is your otp|is the otp|use otp|enter otp|otp is|valid for \d+|never share|do not share|otps are secret)\b|""" +
        """#\d{4,8}\b""",
        Pattern.CASE_INSENSITIVE
    )

    // 2. Non-financial marketing / service / telecom / weather / tracking rejection
    private val NON_FINANCIAL_REGEX = Pattern.compile(
        """\b(?:data usage|data quota|daily data|high speed data|pack validity|recharge|plan expir|airtel thanks|jiofiber|myjio|callertune|hello tune)\b|""" +
        """\b(?:out for delivery|delivered|order placed|order confirmed|shipped|tracking id|courier|awb|dispatch)\b|""" +
        """\b(?:feedback|survey|rate us|rate your|review us|rating|winner|congratulations|claim now|claim your|flat \d+%(?: off)?|use coupon|use code|voucher)\b|""" +
        """\b(?:ready for your|ready for you|waiting for you|at your fingertips|borrow up to|avail up to|get up to)\b|""" +
        """\b(?:pre-approved|preapproved|pre approved|loan offer|instant loan|personal loan|apply now|get a loan|get instant|cash loan)\b|""" +
        """\b(?:cashback offer|scratch card|win up to|earn up to|scratch & win|play & win|rewards? earned|coins? earned|cashback on your|flat .*?cashback|win .*?cashback|earn .*?cashback)\b|""" +
        """\b(?:tap to (?:link|claim|apply|view|avail|pay|activate|recharge)|link now|invite (?:friends|contacts)|refer (?:&|and) earn|referral code|limited period offer)\b|""" +
        """\b(?:collect request|has requested|demanded|authorization request|approve or decline)\b|""" +
        """\b(?:neucoins?|supercoins?|reward points?|bonus points?|cash points?|miles?)\b|""" +
        """\b(?:traded value|contract note|demat|depository|cdsl|nsdl|national stock exchange|bse ltd)\b|""" +
        """\b(?:terms & conditions|privacy policy|kyc update|service request)\b|""" +
        """\b(?:imd|ksdma|ndma|weather|forecast|heavy rain|cyclone|thunderstorm)\b|""" +
        """(?:റീചാർജ്|കാലഹരണപ്പെട്ടു|പ്ലാൻ|ജിയോ|ഡാറ്റ|ഫീഡ്‌ബാക്ക്|ഇടിമിന്നൽ|മഴ|കാറ്റ്)""",
        Pattern.CASE_INSENSITIVE
    )

    // 3. Known non-financial senders (commercial promo/service headers)
    private val NON_FINANCIAL_SENDER_PATTERNS = listOf(
        "FLPKRT", "SWIGGY", "ZOMATO", "DOMINO", "JIOCAR", "JIOVOC", "JIOFIB",
        "AIRTEL", "VODAFO", "VI", "BSNL", "NETFLX", "NDMAEW", "NSETRA", "MYNTRA",
        "BLINKT", "ZEPTO", "TATASKY", "DTH", "UBERIN", "OLACAB", "POLICY", "SHADI"
    )

    // 4. Known financial keywords in sender headers
    private val FINANCIAL_SENDER_KEYWORDS = listOf(
        "HDFC", "SBI", "ICICI", "AXIS", "KOTAK", "FEDBNK", "JTEDGE", "ONECRD",
        "BOBCRD", "BOBONE", "BOB", "CSB", "JIOPBS", "PAYTM", "QCAMZN", "AMZPAY", "JUSPAY",
        "CANBNK", "PNBSMS", "IDFC", "INDUS", "YESBK", "YESBNK", "UNIONB",
        "INDIANB", "CENTBK", "UCOBNK", "IOB", "KVB", "CUB", "SIBLTD",
        "KBL", "TMB", "BNDHAN", "RBL", "SCISMS", "CITIBK", "HSBC", "STANBK",
        "AUBANK", "AUCCB", "EQUITAS", "UJJIVAN", "PAYU", "RAZORP", "EPFO",
        "CRED", "GROWW", "JIOFINANCE", "TATANEU", "BHIM", "ONECARD", "SLICE",
        "FIMONEY", "JUPITER", "NAVI", "SUPER", "GOOGLE", "GPAY", "PHONEPE",
        "PAYZAPP", "FEDMOBILE", "YONO", "AMAZON"
    )

    // 5. Monetary amount required: ₹ 500, Rs. 500.00, INR 1,500, 500.00 INR, etc.
    private val AMOUNT_REGEX = Pattern.compile(
        """(?:(?:rs\.?|inr|₹)\s*[\d,]+(?:\.\d+)?)|(?:[\d,]+(?:\.\d+)?\s*(?:rs\.?|inr|₹))""",
        Pattern.CASE_INSENSITIVE
    )

    // 6. Financial action verbs / transaction contexts
    private val TRANSACTION_VERBS = Pattern.compile(
        """\b(?:debited|debit|credited|credit|paid|spent|sent|transferred|withdrawn|deposited|deposit|refunded|received|payment|paying|repayment|repay|repaid|cleared|settled|reversed|reversal|mandate|autopay|subscription|sip|cancelled|canceled|revoked|deactivated|failed|failure|unsuccessful|declined)\b""",
        Pattern.CASE_INSENSITIVE
    )

    // 7. Balance or account statement keywords
    private val BALANCE_KEYWORDS = Pattern.compile(
        """\b(?:available\s*balance|avail\.?\s*bal(?:ance)?|account\s*balance|closing\s*bal(?:ance)?|""" +
        """current\s*balance|total\s*due|minimum\s*due|min\s*due|amount\s*due|payment\s*due|due\s*(?:date|on|by)|payable\s*(?:by|before)?|bill\s*(?:amount|for|of)|""" +
        """available\s*limit|avl\s*limit|credit\s*limit|outstanding\s*(?:balance|amount|dues))\b""",
        Pattern.CASE_INSENSITIVE
    )

    // 8. Banking account / card identifiers
    private val ACCOUNT_IDENTIFIERS = Pattern.compile(
        """\b(?:a/c|acct|account|card|ending|xx\d{2,4}|x{2,}\d{2,4}|upi|imps|neft|rtgs|wallet|vpa)\b""",
        Pattern.CASE_INSENSITIVE
    )

    fun isFinancial(sender: String, body: String): Boolean {
        if (body.isBlank()) return false

        // 1. Immediately drop OTPs and authentication messages
        if (OTP_AUTH_REGEX.matcher(body).find()) {
            return false
        }

        // 2. Drop non-financial marketing, telecom, weather, delivery, stock trade notes
        if (NON_FINANCIAL_REGEX.matcher(body).find()) {
            return false
        }

        val cleanSender = sender.trim().uppercase()

        // 3. Sender check
        // Check if sender is purely numeric (personal phone numbers like +919876543210 or 9876543210)
        val digitsOnly = cleanSender.replace("+", "").replace("-", "").trim()
        val isNumericSender = digitsOnly.isNotEmpty() && digitsOnly.all { it.isDigit() }
        if (isNumericSender) {
            // Banks in India never send official transaction SMS from personal mobile numbers
            return false
        }

        // Check if sender contains known non-financial company codes
        for (pattern in NON_FINANCIAL_SENDER_PATTERNS) {
            if (cleanSender.contains(pattern)) {
                return false
            }
        }

        // 3.5 Check for AutoPay / Mandate / Subscription cancellation notifications.
        // These are critical financial state updates that frequently omit explicit currency amounts
        // (e.g. "UPI AutoPay for Netflix has been successfully revoked").
        val lowerBody = body.lowercase()
        val isCancellation = (lowerBody.contains("revok") ||
                              lowerBody.contains("cancel") ||
                              lowerBody.contains("deactivat") ||
                              lowerBody.contains("stopped") ||
                              lowerBody.contains("paused")) &&
                             (lowerBody.contains("mandate") ||
                              lowerBody.contains("autopay") ||
                              lowerBody.contains("auto-pay") ||
                              lowerBody.contains("subscription") ||
                              lowerBody.contains("standing instruction") ||
                              lowerBody.contains("si ") ||
                              lowerBody.contains("sip") ||
                              lowerBody.contains("recurring"))
        if (isCancellation) {
            return true
        }

        // 3.6 Check for AutoPay / Mandate / Subscription / SIP debit failure notifications
        // (e.g. "Autopay debit failed for GROWW INVEST TECH PRIVATE LIMITED STOCKS SIP: Autopay debit of ₹1000.00 ... has failed").
        val isAutopayFailure = (lowerBody.contains("failed") ||
                                lowerBody.contains("failure") ||
                                lowerBody.contains("unsuccessful") ||
                                lowerBody.contains("declined") ||
                                lowerBody.contains("could not be processed")) &&
                               (lowerBody.contains("mandate") ||
                                lowerBody.contains("autopay") ||
                                lowerBody.contains("auto-pay") ||
                                lowerBody.contains("subscription") ||
                                lowerBody.contains("standing instruction") ||
                                lowerBody.contains("si ") ||
                                lowerBody.contains("sip") ||
                                lowerBody.contains("recurring") ||
                                lowerBody.contains("deposit"))
        if (isAutopayFailure) {
            return true
        }

        val hasAmount = AMOUNT_REGEX.matcher(body).find()
        val hasTxVerb = TRANSACTION_VERBS.matcher(body).find()
        val hasBalance = BALANCE_KEYWORDS.matcher(body).find()
        val hasAccount = ACCOUNT_IDENTIFIERS.matcher(body).find()

        // Is it a known financial sender?
        val isKnownFinancialSender = FINANCIAL_SENDER_KEYWORDS.any { cleanSender.contains(it) }

        // Must have an amount
        if (!hasAmount) return false

        // If known financial sender: needs a transaction verb or balance keywords
        if (isKnownFinancialSender) {
            return hasTxVerb || hasBalance
        }

        // If unknown sender (e.g. new bank code or gateway):
        // Must have (transaction verb OR balance keyword) AND an explicit account/card/UPI identifier
        return (hasTxVerb || hasBalance) && hasAccount
    }
}
