PRAGMA
foreign_keys = OFF;

DROP TABLE IF EXISTS "Parent";
DROP TABLE IF EXISTS "Packed";
DROP TABLE IF EXISTS "SetHelper";
DROP TABLE IF EXISTS "MarkerOffset";
DROP TABLE IF EXISTS "Marker";
DROP TABLE IF EXISTS "Length";
DROP TABLE IF EXISTS "Format";
DROP TABLE IF EXISTS "Field";
DROP TABLE IF EXISTS "DataType";

-- Defines a field type and its properties.
-- Id is the unique identifier for the field type.
-- Type is how the field is represented in the stream.
-- MinValue is the minimum value for the field.
-- MaxValue is the maximum value for the field.
-- DefaultValue is the default value for the field.
-- Units is the units for the field.
-- MinArrayLength is the minimum number of instances of the field.
-- MaxArrayLength is the maximum number of instances of the field.
-- IsGrowAsNeeded is a flag indicating if the field can grow as needed.
-- Pattern is a regular expression pattern for the field.
-- ComparisonTolerance is the tolerance for comparing floating point values.
-- MinBufferLength is the minimum length of the buffer.
-- MaxBufferLength is the maximum length of the buffer.
CREATE TABLE "DataType"
(
    "Id"                  INTEGER PRIMARY KEY,
    "Type"                INTEGER NOT NULL,
    "MinValue"            TEXT,
    "MaxValue"            TEXT,
    "DefaultValue"        TEXT,
    "Units"               TEXT,
    "MinArrayLength"      INTEGER,
    "MaxArrayLength"      INTEGER,
    "IsGrowAsNeeded"      INTEGER,
    "Pattern"             TEXT,
    "ComparisonTolerance" REAL,
    "MinBufferLength"     INTEGER,
    "MaxBufferLength"     INTEGER
);

-- Defines a field.
-- Id is the unique identifier for the field.
-- Name is the name of the field.
-- DataTypeId is the data type for the field.
CREATE TABLE Field
(
    Id         INTEGER PRIMARY KEY,
    Name       TEXT    NOT NULL,
    DataTypeId INTEGER NOT NULL,
    FOREIGN KEY (DataTypeId) REFERENCES DataType (Id)
);

-- Defines a format.
-- Id is the unique identifier for the format.
-- Name is the name of the format.
-- RootField is the root field of the format.
CREATE TABLE Format
(
    Id        INTEGER PRIMARY KEY,
    Name      TEXT    NOT NULL,
    RootField INTEGER NOT NULL,
    FOREIGN KEY (RootField) REFERENCES Field (Id)
);

-- Supports a variety of methods by which a field's length may be determined.
-- Id is the unique identifier for the length.
-- DataTypeId is the data type for the length.
-- FlagAbsoluteOffsetFromBeginning is the absolute offset from the beginning of the stream at which the length flag is located.
-- FlagRelativeOffsetFromField is the relative offset from the field at which the length flag is located.
-- ValueAbsoluteOffsetFromBeginning is the absolute offset from the beginning of the stream at which the length is located.
-- ValueRelativeOffsetFromField is the relative offset from the field at which the length is located.
-- Continuator is the value that indicates another entry in the field set array follows
-- Terminator is the value that indicates the end of the field set array.
-- FlagMask is the mask to apply to the flag.
-- FlagShift is the shift to apply to the flag.
-- ValueMask is the mask to apply to the length.
-- ValueShift is the shift to apply to the length.
CREATE TABLE Length
(
    Id                               INTEGER PRIMARY KEY,
    DataTypeId                       INTEGER NOT NULL,
    FlagAbsoluteOffsetFromBeginning  INTEGER,
    FLagRelativeOffsetFromField      INTEGER,
    ValueAbsoluteOffsetFromBeginning INTEGER,
    ValueRelativeOffsetFromField     INTEGER,
    Continuator                      INTEGER,
    Terminator                       INTEGER,
    FlagMask                         INTEGER,
    FlagShift                        INTEGER,
    ValueMask                        INTEGER,
    ValueShift                       INTEGER,
    FlagExpression                   TEXT,
    ValueExpression                  TEXT,
    FOREIGN KEY (DataTypeId) REFERENCES DataType (Id)
);

-- There may be times that one or more values must be read ahead in the stream to determine whether a field set follows.
-- Id is the unique identifier for the marker(s) that are going to be looked for.
CREATE TABLE Marker
(
    Id INTEGER PRIMARY KEY
);

-- Associates a marker with one or more byte offsets.
-- marker_id is the existence marker identifier.
-- ByteOffset is the offset from the beginning of the field at which the marker is located.
-- DataTypeId is the data type for the existence marker at the byte offset.
-- Marker is the value that indicates the field exists.
CREATE TABLE MarkerOffset
(
    marker_id   INTEGER NOT NULL,
    ByteOffset INTEGER NOT NULL,
    DataTypeId INTEGER NOT NULL,
    Marker     INTEGER NOT NULL,
    PRIMARY KEY (marker_id, ByteOffset),
    FOREIGN KEY (marker_id) REFERENCES Marker (Id)
);

-- Associates Length properties with a field.
-- format_id is the format identifier.
-- field_id is the field identifier.
-- length_id is the length identifier.
-- marker_id is the marker identifier.
CREATE TABLE SetHelper
(
    format_id INTEGER NOT NULL,
    field_id  INTEGER NOT NULL,
    length_id INTEGER NULL,
    marker_id INTEGER NULL,
    PRIMARY KEY (format_id, field_id),
    FOREIGN KEY (format_id) REFERENCES Format (Id),
    FOREIGN KEY (field_id) REFERENCES Field (Id),
    FOREIGN KEY (length_id) REFERENCES Length (Id),
    FOREIGN KEY (marker_id) REFERENCES Marker (Id)
);

-- Associates a field with a packed field.
-- Id is the unique identifier for the packed field.
-- field_id is the field identifier.
-- LowBit is the low bit of the packed field.
-- HighBit is the high bit of the packed field.
CREATE TABLE Packed
(
    Id      INTEGER NOT NULL,
    field_id INTEGER NOT NULL,
    LowBit  INTEGER NOT NULL,
    HighBit INTEGER NOT NULL,
    PRIMARY KEY (Id, field_id),
    FOREIGN KEY (Id) REFERENCES Field (Id),
    FOREIGN KEY (field_id) REFERENCES Field (Id)
);

-- Defines a parent-child relationship between fields.
-- format_id is the format identifier.
-- ParentId is the parent field identifier.
-- ChildId is the child field identifier.
-- ChildIndex is the index of the child field.
CREATE TABLE Parent
(
    format_id   INTEGER NOT NULL,
    ParentId   INTEGER NOT NULL,
    ChildId    INTEGER NOT NULL,
    ChildIndex INTEGER NOT NULL,
    PRIMARY KEY (format_id, ParentId, ChildId),
    FOREIGN KEY (format_id) REFERENCES Format (Id),
    FOREIGN KEY (ParentId) REFERENCES Field (Id),
    FOREIGN KEY (ChildId) REFERENCES Field (Id)
);

-- Set single instance    
INSERT INTO DataType (Id, Type, MinArrayLength, MaxArrayLength)
VALUES (1, 0, 1, 1);

-- Set optional single instance
INSERT INTO DataType (Id, Type, MinArrayLength, MaxArrayLength)
VALUES (2, 0, 0, 1);

-- Set optional unlimited number of instances
INSERT INTO DataType (Id, Type, MinArrayLength, MaxArrayLength, IsGrowAsNeeded)
VALUES (3, 0, 0, 2147483647, 1);

-- Set 4 to 256 instances
INSERT INTO DataType (Id, Type, MinArrayLength, MaxArrayLength)
VALUES (4, 0, 4, 256);

-- Int32 0 to 1
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (5, 5, "0", "1", "0");

-- Int32 0 to 7
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (6, 5, "0", "7", "0");

-- UInt8 0 to 255
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (7, 2, "0", "255", "0");

-- UInt8 0 to 0
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (8, 2, "0", "0", "0");

-- UInt8 1 to 1
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (9, 2, "1", "1", "1");

-- UInt8 4 to 4
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (10, 2, "4", "4", "4");

-- UInt8 11 to 11
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (11, 2, "11", "11", "11");

-- UInt8 12 to 12
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (12, 2, "12", "12", "12");

-- UInt8 33 to 33
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (13, 2, "33", "33", "33");

-- UInt8 44 to 44
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (14, 2, "44", "44", "44");

-- UInt8 59 to 59
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (15, 2, "59", "59", "59");

-- UInt8 249 to 249
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (16, 2, "249", "249", "249");

-- UInt8 254 to 254
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (17, 2, "254", "254", "254");

-- UInt8 255 to 255
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (18, 2, "255", "255", "255");

-- UInt16 0 to 65535
INSERT INTO DataType (Id, Type, MinValue, MaxValue, DefaultValue)
VALUES (19, 4, "0", "65535", "0");

-- String length 8
INSERT INTO DataType (Id, Type, MinBufferLength, MaxBufferLength)
VALUES (20, 11, "8", "8");

-- Blob length 3
INSERT INTO DataType (Id, Type, MinBufferLength, MaxBufferLength)
VALUES (21, 12, "3", "3");

-- Blob length 0 to 255
INSERT INTO DataType (Id, Type, MinBufferLength, MaxBufferLength)
VALUES (22, 12, "0", "255");

-- String length 3 to 3
INSERT INTO DataType (Id, Type, MinBufferLength, MaxBufferLength, Pattern)
VALUES (10000, 11, "3", "3", "^GIF$");

-- String length 3 to 3
INSERT INTO DataType (Id, Type, MinBufferLength, MaxBufferLength, Pattern)
VALUES (10001, 11, "3", "3", "^89a$");

-- Set single instance
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5000, "GIF89a", 1);

-- String length 3 to 3, pattern ^GIF$
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5001, "Signature", 10000);

-- String length 3 to 3, pattern ^89a$
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5002, "Version", 10001);

-- Set single instance
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5003, "Logical Screen Descriptor", 1);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5004, "Logical Screen Width", 19);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5005, "Logical Screen Height", 19);

-- Int32 0 to 1
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5006, "Global Color Table Flag", 5);

-- Int32 0 to 7
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5007, "Color Resolution", 6);

-- Int32 0 to 1
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5008, "Sort Flag", 5);

-- Int32 0 to 7
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5009, "Size of Global Color Table", 6);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5010, "Logical Screen Descriptor Packed Fields", 7);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5011, "Background Color Index", 7);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5012, "Pixel Aspect Ratio", 7);

-- Set 4 to 256 instances
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5013, "Global Color Table", 4);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5014, "Red", 7);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5015, "Green", 7);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5016, "Blue", 7);

-- Set unlimited instances
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5017, "Blocks", 3);

-- Set unlimited instances
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5018, "Extensions", 3);

-- Set optional single instance
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5019, "Graphic Control Extension", 2);

-- UInt8 33 to 33
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5020, "Extension Introducer", 13);

-- UInt8 249 to 249
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5021, "Graphic Control Label", 16);

-- UInt8 4 to 4
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5022, "Graphic Control Block Size", 10);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5023, "Graphic Control Extension Packed Fields", 7);

-- Int32 0 to 7
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5024, "Disposal Method", 6);

-- Int32 0 to 1
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5025, "User Input Flag", 5);

-- Int32 0 to 1
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5026, "Transparent Color Flag", 5);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5027, "Delay Time", 19);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5028, "Transparent Color Index", 7);

-- UInt8 0 to 0
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5029, "Block Terminator", 8);

-- Set optional single instance
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5030, "Comment Extension", 2);

-- UInt8 254 to 254
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5031, "Comment Label", 17);

-- Set unlimited instances
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5032, "Comment Data", 3);

-- Set optional single instance
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5033, "Plain Text Extension", 2);

-- UInt8 1 to 1
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5034, "Plain Text Label", 9);

-- UInt8 12 to 12
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5035, "Plain Text Block Size", 12);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5036, "Text Grid Left Position", 19);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5037, "Text Grid Top Position", 19);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5038, "Text Grid Width", 19);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5039, "Text Grid Height", 19);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5040, "Character Cell Width", 7);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5041, "Character Cell Height", 7);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5042, "Text Foreground Color Index", 7);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5043, "Text Background Color Index", 7);

-- Set unlimited instances
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5044, "Plain Text Data", 3);

-- Set optional single instance
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5045, "Application Extension", 2);

-- UInt8 255 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5046, "Application Label", 18);

-- UInt8 11 to 11
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5047, "Application Block Size", 11);

-- String length 8
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5048, "Application Identifier", 20);

-- Blob length 3
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5049, "Application Authentication Code", 21);

-- Set unlimited instances
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5050, "Application Data", 3);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5051, "Data Sub-Block Size", 7);

-- Blob length 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5052, "Data Sub-Block Values", 22);

-- Set optional single instance
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5053, "Image", 2);

-- Set single instance
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5054, "Image Descriptor", 1);

-- UInt8 44 to 44
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5055, "Image Separator", 14);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5056, "Image Left Position", 19);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5057, "Image Top Position", 19);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5058, "Image Width", 19);

-- UInt16 0 to 65535
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5059, "Image Height", 19);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5060, "Image Descriptor Packed Fields", 7);

-- Int32 0 to 1
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5061, "Local Color Table Flag", 5);

-- Int32 0 to 1
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5062, "Interlace Flag", 5);

-- Int32 0 to 7
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5063, "Size of Local Color Table", 6);

-- Set 4 to 256 instances
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5064, "Local Color Table", 4);

-- Set single instance
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5065, "Table Based Image Data", 1);

-- UInt8 0 to 255
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5066, "LZW Minimum Code Size", 7);

-- Set unlimited instances
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5067, "Image Data", 3);

-- UInt8 59 to 59
INSERT INTO Field (Id, Name, DataTypeId)
VALUES (5068, "Trailer", 15);

-- UInt8 0 to 255, Relative offset -1
INSERT INTO Length (Id, DataTypeId, FlagAbsoluteOffsetFromBeginning, FlagRelativeOffsetFromField,
                    ValueAbsoluteOffsetFromBeginning, ValueRelativeOffsetFromField, Continuator, Terminator, FlagMask,
                    FlagShift, ValueMask, ValueShift, FlagExpression, ValueExpression)
VALUES (1, 7, NULL, NULL, NULL, -1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- UInt8 33 to 33, Continuator
INSERT INTO Length (Id, DataTypeId, FlagAbsoluteOffsetFromBeginning, FlagRelativeOffsetFromField,
                    ValueAbsoluteOffsetFromBeginning, ValueRelativeOffsetFromField, Continuator, Terminator, FlagMask,
                    FlagShift, ValueMask, ValueShift, FlagExpression, ValueExpression)
VALUES (2, 13, NULL, NULL, NULL, NULL, 33, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- UInt8 0 to 0, Terminator
INSERT INTO Length (Id, DataTypeId, FlagAbsoluteOffsetFromBeginning, FlagRelativeOffsetFromField,
                    ValueAbsoluteOffsetFromBeginning, ValueRelativeOffsetFromField, Continuator, Terminator, FlagMask,
                    FlagShift, ValueMask, ValueShift, FlagExpression, ValueExpression)
VALUES (3, 8, NULL, NULL, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, NULL, NULL);

-- UInt8 59 to 59, Terminator
INSERT INTO Length (Id, DataTypeId, FlagAbsoluteOffsetFromBeginning, FlagRelativeOffsetFromField,
                    ValueAbsoluteOffsetFromBeginning, ValueRelativeOffsetFromField, Continuator, Terminator, FlagMask,
                    FlagShift, ValueMask, ValueShift, FlagExpression, ValueExpression)
VALUES (4, 15, NULL, NULL, NULL, NULL, NULL, 59, NULL, NULL, NULL, NULL, NULL, NULL);

-- UInt8 0 to 255, Global Color Table length pulled from Logical Screen Descriptor Packed Fields
INSERT INTO Length (Id, DataTypeId, FlagAbsoluteOffsetFromBeginning, FlagRelativeOffsetFromField,
                    ValueAbsoluteOffsetFromBeginning, ValueRelativeOffsetFromField, Continuator, Terminator, FlagMask,
                    FlagShift, ValueMask, ValueShift, FlagExpression, ValueExpression)
VALUES (5, 7, NULL, -3, NULL, -3, NULL, NULL, 128, 7, 7, 0, NULL, "Pow(2, [x]+1)");

-- UInt8 0 to 255, Local Color Table length pulled from Image Descriptor Packed Fields
INSERT INTO Length (Id, DataTypeId, FlagAbsoluteOffsetFromBeginning, FlagRelativeOffsetFromField,
                    ValueAbsoluteOffsetFromBeginning, ValueRelativeOffsetFromField, Continuator, Terminator, FlagMask,
                    FlagShift, ValueMask, ValueShift, FlagExpression, ValueExpression)
VALUES (6, 7, NULL, -1, NULL, -1, NULL, NULL, 128, 7, 7, 0, NULL, "Pow(2, [x]+1)");

-- Data Sub-Block Values, Data Sub-Block Size
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5052, 1, NULL);

-- Graphic Control Extension markers for Extension Introducer, Extension Label
INSERT INTO Marker (Id)
VALUES (1);

-- Comment Extension markers for Extension Introducer, Extension Label
INSERT INTO Marker (Id)
VALUES (2);

-- Plain Text Extension markers for Extension Introducer, Extension Label
INSERT INTO Marker (Id)
VALUES (3);

-- Application Extension markers for Extension Introducer, Extension Label
INSERT INTO Marker (Id)
VALUES (4);

-- Image marker for Image Separator
INSERT INTO Marker (Id)
VALUES (5);

-- Graphic Control Extension Introducer = 0x21 
INSERT INTO MarkerOffset (marker_id, ByteOffset, DataTypeId, Marker)
VALUES (1, 0, 7, 33);

-- Graphic Control Extension Label = 0xF9
INSERT INTO MarkerOffset (marker_id, ByteOffset, DataTypeId, Marker)
VALUES (1, 1, 7, 249);

-- Comment Extension Introducer = 0x21 
INSERT INTO MarkerOffset (marker_id, ByteOffset, DataTypeId, Marker)
VALUES (2, 0, 7, 33);

-- Comment Extension Label = 0xFE
INSERT INTO MarkerOffset (marker_id, ByteOffset, DataTypeId, Marker)
VALUES (2, 1, 7, 254);

-- Plain Text Extension Introducer = 0x21 
INSERT INTO MarkerOffset (marker_id, ByteOffset, DataTypeId, Marker)
VALUES (3, 0, 7, 33);

-- Plain Text Extension Label = 0x01
INSERT INTO MarkerOffset (marker_id, ByteOffset, DataTypeId, Marker)
VALUES (3, 1, 7, 1);

-- Application Extension Introducer = 0x21 
INSERT INTO MarkerOffset (marker_id, ByteOffset, DataTypeId, Marker)
VALUES (4, 0, 7, 33);

-- Application Extension Label = 0xFF
INSERT INTO MarkerOffset (marker_id, ByteOffset, DataTypeId, Marker)
VALUES (4, 1, 7, 255);

-- Image Separator = 0x2C
INSERT INTO MarkerOffset (marker_id, ByteOffset, DataTypeId, Marker)
VALUES (5, 0, 7, 44);

-- Global Color Table
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5013, 5, NULL);

-- Extension, Extension Introducer
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5018, 2, NULL);

-- Graphic Control Extension, Markers for Extension Introducer, Extension Label
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5019, NULL, 1);

-- Comment Extension, Markers for Extension Introducer, Extension Label
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5030, NULL, 2);

-- Comments Data, Block Terminator
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5032, 3, NULL);

-- Plain Text Extension, Markers for Extension Introducer, Extension Label
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5033, NULL, 3);

-- Plain Text Data, Block Terminator
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5044, 3, NULL);

-- Application Extension, Markers for Extension Introducer, Extension Label
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5045, NULL, 4);

-- Application Data, Block Terminator
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5050, 3, NULL);

-- Image, Marker for Image Separator
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5053, NULL, 5);

-- Local Color Table
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5064, 6, NULL);

-- Image Data, Block Terminator
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5067, 3, NULL);

-- Trailer, GIF Trailer
INSERT INTO SetHelper (format_id, field_id, length_id, marker_id)
VALUES (1, 5017, 4, NULL);

-- Logical Screen Descriptor Packed Fields - Global Color Table Flag
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5010, 5006, 7, 7);

-- Logical Screen Descriptor Packed Fields - Color Resolution
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5010, 5007, 4, 6);

-- Logical Screen Descriptor Packed Fields - Sort Flag
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5010, 5008, 3, 3);

-- Logical Screen Descriptor Packed Fields - Size of Global Color Table
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5010, 5009, 0, 2);

-- Graphic Control Extension Packed Fields - Disposal Method
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5023, 5024, 2, 4);

-- Graphic Control Extension Packed Fields - User Input Flag
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5023, 5025, 1, 1);

-- Graphic Control Extension Packed Fields - Transparent Color Flag
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5023, 5026, 0, 0);

-- Image Descriptor Packed Fields - Local Color Table Flag
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5060, 5061, 7, 7);

-- Image Descriptor Packed Fields - Interlace Flag
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5060, 5062, 6, 6);

-- Image Descriptor Packed Fields - Sort Flag
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5060, 5008, 5, 5);

-- Image Descriptor Packed Fields - Sort Flag
INSERT INTO Packed (Id, field_id, LowBit, HighBit)
VALUES (5060, 5063, 0, 2);

INSERT INTO Format (Id, Name, RootField)
VALUES (1, "GIF89a", 5000);

-- Signature
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5000, 5001, 0);

-- Version
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5000, 5002, 1);

-- Logical Screen Descriptor
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5000, 5003, 2);

-- Logical Screen Width
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5003, 5004, 0);

-- Logical Screen Height
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5003, 5005, 1);

-- Logical Screen Descriptor Packed Fields
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5003, 5010, 2);

-- Background Color Index
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5003, 5011, 3);

-- Pixex Aspect Ratio
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5003, 5012, 4);

-- Global Color Table
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5000, 5013, 3);

-- Red
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5013, 5014, 0);

-- Green
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5013, 5015, 1);

-- Blue
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5013, 5016, 2);

-- Blocks
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5000, 5017, 4);

-- Extensions
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5017, 5018, 0);

-- Graphic Control Extension
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5018, 5019, 0);

-- Extension Introducer
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5019, 5020, 0);

-- Graphic Control Label
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5019, 5021, 1);

-- Graphic Control Block Size
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5019, 5022, 2);

-- Graphic Control Extension Packed Fields
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5019, 5023, 3);

-- Delay Time
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5019, 5027, 4);

-- Transparent Color Index
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5019, 5028, 5);

-- Block Terminator
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5019, 5029, 6);

-- Comment Extension
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5018, 5030, 1);

-- Extension Introducer
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5030, 5020, 0);

-- Comment Label
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5030, 5031, 1);

-- Comment Data Node
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5030, 5032, 2);

-- Data Sub-Block Size
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5032, 5051, 0);

-- Data Sub-Block Values
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5032, 5052, 1);

-- Block Terminator
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5030, 5029, 3);

-- Plain Text Extension
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5018, 5033, 2);

-- Extension Introducer
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5020, 0);

-- Plain Text Label
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5034, 1);

-- Plain Text Block Size
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5035, 2);

-- Text Grid Left Position
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5036, 3);

-- Text Grid Top Position
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5037, 4);

-- Text Grid Width
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5038, 5);

-- Text Grid Height
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5039, 6);

-- Character Cell Width
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5040, 7);

-- Character Cell Height
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5041, 8);

-- Text Foreground Color Index
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5042, 9);

-- Text Background Color Index
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5043, 10);

-- Plain Text Data
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5044, 11);

-- Data Sub-Block Size
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5044, 5051, 0);

-- Data Sub-Block Values
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5044, 5052, 1);

-- Block Terminator
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5033, 5029, 12);

-- Application Extension
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5018, 5045, 3);

-- Extension Introducer
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5045, 5020, 0);

-- Application Label
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5045, 5046, 1);

-- Application Block Size
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5045, 5047, 2);

-- Application Idenitfier
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5045, 5048, 3);

-- Application Authentication Code
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5045, 5049, 4);

-- Application Data
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5045, 5050, 5);

-- Data Sub-Block Size
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5050, 5051, 0);

-- Data Sub-Block Values
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5050, 5052, 1);

-- Block Terminator
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5045, 5029, 6);

-- Image
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5017, 5053, 1);

-- Image Descriptor
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5053, 5054, 0);

-- Image Separator
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5054, 5055, 0);

-- Image Left Position
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5054, 5056, 1);

-- Image Top Position
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5054, 5057, 2);

-- Image Width
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5054, 5058, 3);

-- Image Height
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5054, 5059, 4);

-- Image Descriptor Packed Fields
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5054, 5060, 5);

-- Local Color Table
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5053, 5064, 1);

-- Red
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5064, 5014, 0);

-- Green
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5064, 5015, 1);

-- Blue
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5064, 5016, 2);

-- Table Based Image Data
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5053, 5065, 2);

-- LZW Minimum Code Size
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5065, 5066, 0);

-- Image Data
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5065, 5067, 1);

-- Data Sub-Block Size
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5067, 5051, 0);

-- Data Sub-Block Values
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5067, 5052, 1);

-- Block Terminator
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5065, 5029, 2);

-- Trailer
INSERT INTO Parent (format_id, ParentId, ChildId, ChildIndex)
VALUES (1, 5000, 5068, 5);

PRAGMA
foreign_keys = ON;