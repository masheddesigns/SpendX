package com.mashingdesigns.spend_x

import org.junit.Assert.*
import org.junit.Test

class FinancialSmsFilterTest {

    @Test
    fun testValidBankDebitAccepted() {
        val sender = "VM-HDFCBK"
        val body = "Rs 1,250.00 debited from A/C **4582 on 18-Nov-26 towards SWIGGY. Avl Bal: Rs 45,210.50"
        assertTrue("Valid bank debit SMS must be classified as financial", FinancialSmsFilter.isFinancial(sender, body))

        val parsed = FinancialSmsFilter.extractAmountAndDirection(body)
        assertNotNull(parsed)
        assertEquals("1,250.00", parsed!!.first)
        assertTrue("Debit transaction must be expense (isExpense = true)", parsed.second)
    }

    @Test
    fun testValidBankCreditAccepted() {
        val sender = "AD-SBIINB"
        val body = "Dear Customer, your A/C 9876543210 is credited by INR 25,000.00 on 18/11/26 by UPI/salary. Avl Bal INR 1,02,400.00"
        assertTrue("Valid bank credit SMS must be classified as financial", FinancialSmsFilter.isFinancial(sender, body))

        val parsed = FinancialSmsFilter.extractAmountAndDirection(body)
        assertNotNull(parsed)
        assertEquals("25,000.00", parsed!!.first)
        assertFalse("Credit transaction must be income (isExpense = false)", parsed.second)
    }

    @Test
    fun testOtpMessageRejected() {
        val sender = "VM-HDFCBK"
        val body = "123456 is your OTP for transaction of INR 5,000.00 at Amazon. Valid for 10 mins. Do not share OTP with anyone."
        assertFalse("OTP message must be strictly dropped regardless of sender or amount", FinancialSmsFilter.isFinancial(sender, body))
    }

    @Test
    fun testNonFinancialMarketingDropped() {
        val sender = "VK-SWIGGY"
        val body = "Get up to 50% off on your next order! Use coupon HUNGRY. Order placed tracking ID #8921"
        assertFalse("Marketing and order tracking SMS must be dropped", FinancialSmsFilter.isFinancial(sender, body))
    }

    @Test
    fun testTelecomDataAlertDropped() {
        val sender = "AD-AIRTEL"
        val body = "You have exhausted 100% of your daily high speed data quota. Recharge with Rs 19 for 1GB pack validity."
        assertFalse("Telecom quota / recharge reminders must be dropped", FinancialSmsFilter.isFinancial(sender, body))
    }

    @Test
    fun testNumericSenderDropped() {
        val sender = "+919876543210"
        val body = "Rs 500 debited for dinner yesterday. Please pay via UPI."
        assertFalse("Messages from numeric phone numbers must be dropped as non-official", FinancialSmsFilter.isFinancial(sender, body))
    }

    @Test
    fun testAutoPayRevocationAcceptedWithoutExplicitAmount() {
        val sender = "VM-HDFCBK"
        val body = "UPI AutoPay mandate for Netflix has been successfully revoked as per your request."
        assertTrue("Mandate/AutoPay cancellation must be classified as financial even without amount", FinancialSmsFilter.isFinancial(sender, body))
    }

    @Test
    fun testAutoPayDebitFailureAccepted() {
        val sender = "VK-AXISBK"
        val body = "Autopay debit of Rs 1000.00 failed for GROWW INVEST TECH PRIVATE LIMITED STOCKS SIP due to insufficient funds."
        assertTrue("AutoPay debit failure notifications must be retained", FinancialSmsFilter.isFinancial(sender, body))
    }

    @Test
    fun testUnknownSenderWithAccountIdentifierAccepted() {
        val sender = "TX-NEOBNK" // Unknown header not in known financial list
        val body = "Rs 350.00 paid from card ending xx9012 via POS. Avl limit: Rs 50,000"
        assertTrue("Unknown sender with account identifier and valid transaction verb must be accepted", FinancialSmsFilter.isFinancial(sender, body))
    }

    @Test
    fun testUnknownSenderWithoutAccountIdentifierRejected() {
        val sender = "TX-RANDOM"
        val body = "Rs 350.00 paid for services rendered at clinic."
        assertFalse("Unknown sender without account/card/UPI identifier must be dropped", FinancialSmsFilter.isFinancial(sender, body))
    }
}
