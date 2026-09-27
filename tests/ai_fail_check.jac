import time;
import server.ai as ai;
import server.availability as availability;
with entry:__main__ {
    t = time.time();
    (rules, used) = availability.parse_note("No Fridays before 10");
    print("used_ai:", used, "rules:", len(rules), "secs:", round(time.time() - t, 1));
    print("last_error:", ai.last_error[:300]);
    t = time.time();
    (rules2, used2) = availability.parse_note("No Fridays before 10");
    print("second call (cooldown) used_ai:", used2, "secs:", round(time.time() - t, 2));
}
