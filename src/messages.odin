package sqlodin

Prepare_Scope :: enum u8 {
	Global,
	Bounded,
}

Prepare_Message :: struct {
	ballot: Ballot,
	first:  Slot,
	last:   Slot,
	scope:  Prepare_Scope,
}

Promise_Message :: struct($Value: typeid) {
	ballot: Ballot,
	slot:   Slot,
	vote:   Ballot,
	state:  Cell_State,
	value:  ^Value,
}

Promise_Range_Message :: struct {
	ballot:         Ballot,
	anchor:         Trim_Anchor,
	chosen_through: Slot,
	first:          Slot,
	last:           Slot,
	reported:       u32,
	more:           bool,
}

Accept_Message :: struct($Value: typeid) {
	ballot: Ballot,
	slot:   Slot,
	value:  ^Value,
}

Accepted_Message :: struct {
	ballot:          Ballot,
	slot:            Slot,
	decided_through: Slot,
}

Commit_Message :: struct($Value: typeid) {
	slot:  Slot,
	value: ^Value,
}

Learn_Message :: struct {
	from_slot: Slot,
	count:     u32,
}

Nack_Message :: struct {
	rejected:        Ballot,
	promised:        Ballot,
	slot:            Slot,
	decided_through: Slot,
}

Heartbeat_Message :: struct {
	ballot:          Ballot,
	decided_through: Slot,
}

Skip_Message :: struct {
	slot:            Slot,
	ballot:          Ballot,
	owner:           Node_Id,
	decided_through: Slot,
}

Message :: union($Value: typeid) {
	Prepare_Message,
	Promise_Message(Value),
	Promise_Range_Message,
	Accept_Message(Value),
	Accepted_Message,
	Commit_Message(Value),
	Learn_Message,
	Nack_Message,
	Heartbeat_Message,
	Skip_Message,
}

Envelope :: struct($Value: typeid) {
	from:    Node_Id,
	to:      Node_Id,
	message: Message(Value),
}

Committed :: struct($Value: typeid) {
	slot:  Slot,
	value: ^Value,
}

message_value :: proc(msg: Message($Value)) -> (^Value, bool) {
	switch m in msg {
	case Promise_Message(Value): return m.value, true
	case Accept_Message(Value):  return m.value, true
	case Commit_Message(Value):  return m.value, true
	case Prepare_Message, Promise_Range_Message, Accepted_Message,
	     Learn_Message, Nack_Message, Heartbeat_Message, Skip_Message:
		return nil, false
	}
	return nil, false
}
