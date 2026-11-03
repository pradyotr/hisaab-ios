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

The **Spends** tab lists every spend, newest first. A message icon means it came from an SMS. A hand icon means you added it.

- **Add**: tap **+**. Use this for cash and for anything the SMS automation missed.
- **Edit**: tap a spend to change the amount, merchant, note or date. Spends from SMS also show the original message.
- **Delete**: swipe left on a spend, then tap **Delete**. Budgets recalculate immediately.

## Trends

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

To hide amounts on the normal **Hisaab** widget too, turn on **Settings → Hide amounts on lock screen**.

The widget changes to the new day's budget at midnight. It refreshes after every new spend.

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
