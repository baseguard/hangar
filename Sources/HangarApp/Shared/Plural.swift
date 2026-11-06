/// "host" or "hosts", by the count before it.
func counted(_ count: Int, _ noun: String) -> String {
    count == 1 ? noun : noun + "s"
}
