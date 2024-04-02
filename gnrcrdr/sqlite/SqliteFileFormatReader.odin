package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import "../metadata"
import sql "../../sqlite3"

readFileFormat :: proc(dbFilePath: string, formatId: i32, fileFormat: ^metadata.FileFormat) {
	log.debugf("Opening database and reading format ID %v", formatId)
	db, err := db_init(strings.clone_to_cstring(dbFilePath))
	db_check(db, err)
	defer db_destroy(db)

	result := readDataType(db, &fileFormat.metadataProvider.dataTypeMap)

	result = readLength(db, &fileFormat.metadataProvider.setLengthMap)

	result = readMarkerOffset(db, &fileFormat.metadataProvider.markerOffsetMap)

	result = readSetHelper(db, &fileFormat.metadataProvider.setHelperMap)

	packedRecords := make([dynamic]^metadata.PackedRecord)

	result = readPacked(db, &packedRecords)

  fileFormat.metadataProvider.packedRecords = packedRecords

  result = readField(db, packedRecords[:], &fileFormat.metadataProvider.fieldMetadataMap)

  result = readFormat(db, &fileFormat.metadataProvider.formatRecord)

	result = readParent(db, &fileFormat.metadataProvider.parentMap)

	fileFormat.rootMetadataTreeNode.fieldMetadata = fileFormat.metadataProvider.fieldMetadataMap[fileFormat.metadataProvider.formatRecord.rootField]

	readChildren(&fileFormat.rootMetadataTreeNode, &fileFormat.metadataProvider)
}

@(private="file")
readChildren :: proc(parentTreeNode: ^metadata.FieldMetadataTreeNode, fieldMetadataProvider: ^metadata.FieldMetadataProvider) {

  parentMap := &fieldMetadataProvider.parentMap
  fieldMetadataMap := &fieldMetadataProvider.fieldMetadataMap

	for childRecord in parentMap[parentTreeNode.fieldMetadata.id] {

		childTreeNode := new(metadata.FieldMetadataTreeNode)

		childTreeNode.fieldMetadata = fieldMetadataMap[childRecord.childId]

		childTreeNode.parent = parentTreeNode

		append(&parentTreeNode.children, childTreeNode)

		readChildren(childTreeNode, fieldMetadataProvider)
  }
}
