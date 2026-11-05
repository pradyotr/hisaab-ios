# Hisaab

A personal budget tracker for iPhone. Hisaab gives you a daily spend budget on the lock screen, tracks spends from your bank SMS, and shows how much you saved or overspent each day and month.

## Set your budget

The first time you open the app:

1. Enter your **monthly income**.
2. Choose a goal:
   - **Save**: enter how much you want to save. Hisaab shows how much you can spend.
   - **Spend at most**: enter your spending limit. Hisaab shows how much you will save.
3. Set the day your **budget cycle starts** (1–28). Use your salary day if you are paid mid-month.
4. Tap **Start tracking**.

To change these later, go to **Settings → Budget**.

To set light or dark mode for the app, go to **Settings → Appearance**. **System** follows your iPhone's setting.

## How the daily budget works

Each day's budget = money left in the cycle ÷ days left (including today). The amount is fixed at the start of each day.

- If you spend less than today's budget, the rest is spread over the remaining days, so tomorrow's budget goes up.
- If you spend more, tomorrow's budget goes down.
- If you have spent the whole cycle's money, the daily budget is 0.

## Today

The **Today** tab shows:

- **Today**: the daily budget, the amount spent, and how much is left or how much you are over. The gauge shows the % used.
- **This cycle**: the spend cap, the total spent, the amount remaining, and the days left.

Tap **+** to add a spend.

## Spends

The **Spends** tab lists all money in and out, newest first. A message icon means it came from an SMS. A hand icon means you added it. Other icons show the type. Money in has a **+** and is green.

- **Add**: tap **+**. Use this for cash and for anything the SMS automation missed.
- **Edit**: tap an entry to change the amount, merchant, note, date or type. Entries from SMS also show the original message and the reference number.
- **Delete**: swipe left on an entry, then tap **Delete**. Budgets recalculate immediately.
- **Quick fixes**: touch and hold an entry. Then select **Mark as** and a type, **On a credit card**, or **Don't count it**.

## Types

| Type | How it counts |
|---|---|
| **Spend** | In full, on its date. |
| **Credit card bill payment** | Only the part that your tracked card spends do not cover. |
| **Savings / investment** | Not counted. It is shown as **Invested** on the Today screen. |
| **Refund** | Lowers what you spent, on the day the money comes back. |
| **Cashback** | Lowers what you spent, on the day it is credited. |
| **Reversal** | Cancels the payment it is linked to, as if it never happened. If it is not linked, it counts like a refund. |
| **Other credit** | Not counted. Examples are salary and money from friends. |

**Don't count** keeps an entry in the list but counts it as 0. Use it for transfers to your own accounts.

### Credit cards

A credit card purchase counts on the day you buy. The card bill does not count it again:

- A bill covers the open card spends from on or before the bill's date, oldest first. If the bill and the spend both have card digits, the digits must match.
- If you pay less than the open card spends, the bill counts 0. The rest stays open for the next bill.
- A refund or cashback on a card makes the next bill smaller. Hisaab takes this into account, so the bill does not count it again.

An SMS that says "credit card" is a card spend. An SMS that pays a card bill (for example "towards your Credit Card", "card bill" or a payment to CRED) is a bill payment. The card company's "payment received" SMS is ignored, because the bank's debit SMS for the same payment is counted.

Some banks write only "Card XX1234". To make Hisaab treat these as credit card spends, add the card's last 4 digits in **Settings → Credit cards**. This applies to new SMS only. To fix older entries, change them with a long press.

### Savings

A debit to an investment platform is savings, not a spend. Hisaab knows Groww, Zerodha, Upstox, Kuvera, Paytm Money, Angel One, INDmoney, ET Money, smallcase, ICCL, NSE Clearing, BSE, CAMS, KFintech and NPS. It also finds SMS that say "mutual fund" or "SIP". To add another recipient, go to **Settings → Savings recipients** and enter a word from its name or UPI ID.

### Refunds, reversals and cashback

- When a reversal SMS arrives, Hisaab links it to the payment it cancels. It first looks for the same reference number. If there is none, it looks for the most recent debit with the same amount in the 7 days before. Each debit can be cancelled only once. To change the link, edit the reversal and pick the payment in **Cancels**.
- If you delete a payment that a reversal cancels, the reversal is set to **Don't count**.
- SMS about money that is still on its way are ignored. Examples: "will be reversed", "will be refunded", "refund initiated". The SMS that says the money arrived is the one that counts.
- If your bank and your UPI app both send an SMS for the same payment, the second one is skipped when the reference number and amount match.

## Trends

Tap a bar to see its date, the amount saved or exceeded, the amount spent, and the % used. Tap the bar again to close it.

- **Daily**: one bar for each day of the current cycle. The bar is that day's budget minus that day's spend. Green bars above the line mean you saved. Red bars below the line mean you overspent.
- **Monthly**: one bar for each cycle. The bar is the spend cap minus the total spent.

The daily bars do not add up to the monthly bar. Each day's budget is recalculated from the money left.

## Lock screen widget

1. Long-press the lock screen, then tap **Customize** → **Lock Screen**.
2. Tap the widget area below the clock, then select **Hisaab**.
3. Pick a widget:
   - **Hisaab**: today's budget, the amount used and the % used.
   - **Hisaab (Private)**: % used only, with no amounts.
   - **Hisaab (Cycle)**: a circular gauge with the % of this cycle's spend cap used. It has a calendar icon.

The **Hisaab** and **Hisaab (Private)** widgets come in three sizes: rectangular, circular (a % gauge) and inline (above the clock). **Hisaab (Cycle)** is circular only.

## Home screen widget

1. Long-press an empty area of the home screen, then tap **Edit** → **Add Widget**.
2. Search for **Hisaab**, then swipe to the widget and size you want:
   - **Hisaab**, small: the money left today, today's budget, the amount used and the % used.
   - **Hisaab**, medium: today on the left, and this cycle (% of the spend cap used, the amount spent and the days left) on the right.
   - **Hisaab (Private)**, small or medium: the same layouts with percentages only.
   - **Hisaab (Cycle)**, small: a ring with the % of this cycle's spend cap used.
3. Tap **Add Widget**.

The bars and the ring are green while you are within budget. They turn red when you go over it.

## Hide amounts

To hide amounts on the **Hisaab** and **Hisaab (Cycle)** widgets too, turn on **Settings → Hide amounts in widgets**. This applies to the lock screen and the home screen.

The widgets change to the new day's budget at midnight. They refresh after every new spend.

## Track spends from bank SMS

iPhone apps cannot read your messages. Hisaab uses a Shortcuts automation instead. You set it up once:

1. Open **Shortcuts** → **Automation** → **+** → **Message**.
2. Set **Sender** to your bank's SMS ID, or set **Message Contains** to `debited`.
3. Select **Run Immediately**. Then tap **New Blank Automation**. Do not tap the suggested Hisaab action: then iOS hides the **Message** field and asks you to type the text each time.
4. Tap **Add Action** and add **Log Bank SMS** (Hisaab). Tap the blue word **Message** and select **Shortcut Input**. The action then shows "Log Shortcut Input in Hisaab".
5. Make one automation for each bank, or for each other keyword such as `spent`.

Hisaab ignores OTPs, credits, refunds, failed transactions, payment reminders and UPI money requests. If the same SMS arrives twice within 10 minutes, Hisaab logs it only once.

## Check and troubleshoot

Go to **Settings → Diagnostics**:

- **Shared storage**: must say **OK**. If it says **NOT SHARED**, the widget cannot read your data. Re-install the app with AltStore.
- **Test SMS parser**: paste a bank SMS to see the amount, merchant and rule Hisaab finds. Tap **Log it** to add it as a spend.
- **Debug log**: one line each time an SMS reaches the app, with the result (logged, ignored and why, or duplicate). If a bank SMS arrives and no line appears, the automation did not run. Check its trigger. Tap **Clear** to empty the log. This does not change your spends.
