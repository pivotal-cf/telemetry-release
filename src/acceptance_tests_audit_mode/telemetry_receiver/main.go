package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	PortEnvVar         = "PORT"
	ApiKeysEnvVar      = "VALID_API_KEYS"
	MessageLimitEnvVar = "MESSAGE_LIMIT"

	RequiredEnvVarNotSetErrorFormat = "%s environment variable not set"
	FailedUnmarshalErrorFormat      = "%s failed to json unmarshal"
	InvalidMessageLimitError        = "message limit configuration invalid"
)

var (
	userApiKeys   map[string][]string
	messages      map[string][]map[string]interface{}
	batchMessages map[string][]map[string]interface{}

	messageLimit int
)

func main() {
	if err := validateEnvConfigured(); err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}

	bindAddr := fmt.Sprintf(":%s", os.Getenv(PortEnvVar))

	messages = map[string][]map[string]interface{}{}
	batchMessages = map[string][]map[string]interface{}{}
	http.HandleFunc("/collections/batch", postMessageHandler(readTarBatch, batchMessages))
	http.HandleFunc("/components", postMessageHandler(readJSONBatch, messages))
	http.HandleFunc("/received_messages", readMessagesForUser(messages))
	http.HandleFunc("/received_batch_messages", readMessagesForUser(batchMessages))
	http.HandleFunc("/clear_messages", clearMessages)
	http.HandleFunc("/up", upHandler)

	err := http.ListenAndServe(bindAddr, nil)
	if err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}
}

func postMessageHandler(
	messageReader func(contents []byte, contentEncoding string) ([]map[string]interface{}, error),
	messagesToUpdate map[string][]map[string]interface{}) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, authed := authenticated(r.Header, userApiKeys)
		if !authed {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		reqBody, err := io.ReadAll(r.Body)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		defer r.Body.Close()
		recMessages, err := messageReader(reqBody, r.Header.Get("Content-Encoding"))
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}

		updateMessages(userID, messagesToUpdate, recMessages)

		w.WriteHeader(http.StatusCreated)
	}
}

func updateMessages(userID string, messagesToUpdate map[string][]map[string]interface{}, receivedMessages []map[string]interface{}) {
	currMessages, ok := messagesToUpdate[userID]
	if !ok {
		currMessages = []map[string]interface{}{}
	}

	messagesToRemove := len(receivedMessages) + len(currMessages) - messageLimit

	if messagesToRemove > 0 {
		currMessages = currMessages[messagesToRemove:]
	}
	messagesToUpdate[userID] = append(currMessages, receivedMessages...)
}

func readMessagesForUser(receivedMessages map[string][]map[string]interface{}) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, authed := authenticated(r.Header, userApiKeys)
		if !authed {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		userMessages, ok := receivedMessages[userID]
		if ok {
			msgBytes, err := json.Marshal(&userMessages)
			if err != nil {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			_, _ = w.Write(msgBytes)
		} else {
			_, _ = w.Write([]byte("[]"))
		}
	}
}

func clearMessages(w http.ResponseWriter, r *http.Request) {
	userID, authed := authenticated(r.Header, userApiKeys)
	if !authed {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	delete(messages, userID)
	delete(batchMessages, userID)
}

type UpResponse struct {
	Status    string `json:"status"`
	AppName   string `json:"app_name"`
	OrgName   string `json:"org_name"`
	SpaceName string `json:"space_name"`
}

func upHandler(w http.ResponseWriter, r *http.Request) {
	vcapApplication := os.Getenv("VCAP_APPLICATION")
	var appInfo map[string]interface{}
	if vcapApplication != "" {
		_ = json.Unmarshal([]byte(vcapApplication), &appInfo)
	}

	response := UpResponse{
		Status:    "200",
		AppName:   getString(appInfo, "application_name", "local"),
		OrgName:   getString(appInfo, "organization_name", "local"),
		SpaceName: getString(appInfo, "space_name", "local"),
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(response)
}

func getString(data map[string]interface{}, key, defaultValue string) string {
	if value, exists := data[key]; exists {
		if strValue, ok := value.(string); ok {
			return strValue
		}
	}
	return defaultValue
}

func authenticated(h http.Header, validUserApiKeys map[string][]string) (string, bool) {
	authHeaderToken := tokenFromHeader(h)
	for userID, keys := range validUserApiKeys {
		for _, validUserKey := range keys {
			if authHeaderToken == validUserKey {
				return userID, true
			}
		}
	}
	return "", false
}

func tokenFromHeader(h http.Header) string {
	authHeader := h.Get("Authorization")
	authHeaderParts := strings.Split(authHeader, " ")
	if len(authHeaderParts) != 2 || (authHeaderParts[0] != "Bearer") {
		return ""
	}
	return authHeaderParts[1]
}

func validateEnvConfigured() error {
	requiredEnvVars := []string{
		PortEnvVar,
		ApiKeysEnvVar,
		MessageLimitEnvVar,
	}

	for _, e := range requiredEnvVars {
		value := os.Getenv(e)
		if value == "" {
			return fmt.Errorf(RequiredEnvVarNotSetErrorFormat, e)
		}
	}

	err := json.Unmarshal([]byte(os.Getenv(ApiKeysEnvVar)), &userApiKeys)
	if err != nil {
		return fmt.Errorf(FailedUnmarshalErrorFormat+": %w", ApiKeysEnvVar, err)
	}

	messageLimit, err = strconv.Atoi(os.Getenv(MessageLimitEnvVar))
	if err != nil {
		return fmt.Errorf(InvalidMessageLimitError+": %w", err)
	}

	return nil
}

func readJSONBatch(batchContents []byte, _ string) ([]map[string]interface{}, error) {
	decoder := json.NewDecoder(bytes.NewReader(batchContents))
	var jsonObjSlice []map[string]interface{}
	for {
		var jsonObj map[string]interface{}

		if err := decoder.Decode(&jsonObj); err == io.EOF {
			break
		} else if err != nil {
			return nil, err
		}
		jsonObjSlice = append(jsonObjSlice, jsonObj)

	}
	return jsonObjSlice, nil
}

func readTarBatch(contents []byte, contentEncoding string) ([]map[string]interface{}, error) {

	var tarReader *tar.Reader

	bytesReader := bytes.NewReader(contents)
	if contentEncoding == "gzip" {
		gzipReader, err := gzip.NewReader(bytesReader)
		if err != nil {
			return nil, fmt.Errorf("failed to read gzip contents: %w", err)
		}
		tarReader = tar.NewReader(gzipReader)
	} else {
		tarReader = tar.NewReader(bytesReader)
	}

	var messagesInTar []map[string]interface{}
	for {
		hdr, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("failed to read header: %w", err)
		}

		if hdr.Typeflag == tar.TypeReg {
			if strings.HasSuffix(hdr.Name, "metadata") {
				metadata := struct {
					CollectedAt  string
					FoundationId string
				}{}

				err := json.NewDecoder(tarReader).Decode(&metadata)
				if err != nil {
					return nil, fmt.Errorf("failed to read file contents %s: %w", hdr.Name, err)
				}

				messagesInTar = append(messagesInTar, map[string]interface{}{
					"FoundationId": metadata.FoundationId,
					"CollectedAt":  metadata.CollectedAt,
					"Dataset":      filepath.Dir(hdr.Name),
				})
			}
		}
	}

	return messagesInTar, nil
}
