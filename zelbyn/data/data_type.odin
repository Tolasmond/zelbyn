package data

Data_Type :: enum u8 {
	Set,
	Int8,
	UInt8,
	Int16,
	UInt16,
	Int32,
	UInt32,
	Int64,
	UInt64,
	Float32,
	Float64,
	String,
	Blob,
	Bool, // a bit type of 1 bit (b1)
	Bits, // any other bit type (and b1 with an enum): an unsigned integer of Node.width bits, whose values are of the smallest unsigned type that holds them
}
