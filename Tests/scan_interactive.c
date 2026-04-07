// Interactive scan: CreateScanJob → wait for ENTER → RetrieveImage
// Press ENTER when you see "HP" blinking on the printer screen
// cc -o scan_interactive scan_interactive.c -I/opt/homebrew/include/libusb-1.0 -L/opt/homebrew/lib -lusb-1.0

#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>

#define NS \
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" \
    "<SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://www.w3.org/2003/05/soap-envelope\" " \
    "xmlns:SOAP-ENC=\"http://www.w3.org/2003/05/soap-encoding\" " \
    "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" " \
    "xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" " \
    "xmlns:wscn=\"http://tempuri.org/wscn.xsd\">" \
    "<SOAP-ENV:Body>"
#define NE "</SOAP-ENV:Body></SOAP-ENV:Envelope>"

static int find_sequence(const unsigned char *data, int data_len, const unsigned char *needle, int needle_len, int start) {
    if (!data || !needle || data_len <= 0 || needle_len <= 0 || data_len < needle_len) return -1;
    if (start < 0) start = 0;
    for (int i = start; i <= data_len - needle_len; i++) {
        if (memcmp(data + i, needle, needle_len) == 0) return i;
    }
    return -1;
}

static int pad4(int n) {
    int r = n % 4;
    return r == 0 ? 0 : (4 - r);
}

static uint32_t be32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int decode_http_chunked_body(const unsigned char *buf, int total, unsigned char **decoded_out, int *decoded_len_out) {
    static const unsigned char http_marker[] = "HTTP/1.1";
    static const unsigned char header_sep[] = "\r\n\r\n";
    static const unsigned char crlf[] = "\r\n";

    int http_start = find_sequence(buf, total, http_marker, (int)sizeof(http_marker) - 1, 0);
    if (http_start < 0) return -1;

    int header_end = find_sequence(buf, total, header_sep, 4, http_start);
    if (header_end < 0) return -2;

    int body_start = header_end + 4;
    if (body_start >= total) return -3;

    unsigned char *decoded = malloc((size_t)total);
    if (!decoded) return -4;

    int pos = body_start;
    int out_len = 0;
    int chunks = 0;

    while (pos < total) {
        int line_end = find_sequence(buf, total, crlf, 2, pos);
        if (line_end < 0) break;

        int line_len = line_end - pos;
        if (line_len <= 0) {
            pos = line_end + 2;
            continue;
        }

        char hex_str[32] = {0};
        int copy_len = line_len < (int)sizeof(hex_str) - 1 ? line_len : (int)sizeof(hex_str) - 1;
        memcpy(hex_str, buf + pos, (size_t)copy_len);

        char *semi = strchr(hex_str, ';');
        if (semi) *semi = '\0';

        char *endptr = NULL;
        unsigned long chunk_size = strtoul(hex_str, &endptr, 16);
        if (endptr == hex_str) break;

        pos = line_end + 2;
        if (chunk_size == 0) break;

        if ((unsigned long)(total - pos) < chunk_size) {
            free(decoded);
            return -5;
        }

        memcpy(decoded + out_len, buf + pos, chunk_size);
        out_len += (int)chunk_size;
        pos += (int)chunk_size;

        if (pos + 1 < total && buf[pos] == '\r' && buf[pos + 1] == '\n') pos += 2;
        chunks++;
    }

    // Fallback: if chunk parse failed, at least return raw HTTP body
    if (out_len == 0) {
        out_len = total - body_start;
        memcpy(decoded, buf + body_start, (size_t)out_len);
    }

    printf("Decoded chunked body: %d bytes (%d chunks)\n", out_len, chunks);
    *decoded_out = decoded;
    *decoded_len_out = out_len;
    return 0;
}

static int extract_image_from_dime(const unsigned char *dime, int dime_len, unsigned char **image_out, int *image_len_out, char *mime_out, int mime_cap) {
    if (!dime || dime_len <= 12) return -1;

    unsigned char *image = malloc((size_t)dime_len);
    if (!image) return -2;

    if (mime_out && mime_cap > 0) mime_out[0] = '\0';

    int offset = 0;
    int out_len = 0;
    int collecting = 0;
    int record = 0;

    while (offset + 12 <= dime_len) {
        const unsigned char *h = dime + offset;
        int cf = h[0] & 0x01;
        int options_len = ((int)h[2] << 8) | h[3];
        int id_len = ((int)h[4] << 8) | h[5];
        int type_len = ((int)h[6] << 8) | h[7];
        uint32_t data_len_u32 = be32(h + 8);
        if (data_len_u32 > 50 * 1024 * 1024) { free(image); return -3; }
        int data_len = (int)data_len_u32;

        int pos = offset + 12;
        if (pos + options_len > dime_len) break;
        pos += options_len + pad4(options_len);

        if (pos + id_len > dime_len) break;
        const unsigned char *id_ptr = dime + pos;
        pos += id_len + pad4(id_len);

        if (pos + type_len > dime_len) break;
        const unsigned char *type_ptr = dime + pos;
        pos += type_len + pad4(type_len);

        if (pos + data_len > dime_len) break;
        const unsigned char *payload = dime + pos;

        char type_buf[64] = {0};
        int type_copy = type_len < (int)sizeof(type_buf) - 1 ? type_len : (int)sizeof(type_buf) - 1;
        if (type_copy > 0) memcpy(type_buf, type_ptr, (size_t)type_copy);

        int is_image_type = (type_len >= 6 && memcmp(type_ptr, "image/", 6) == 0);
        if (!collecting && is_image_type) {
            collecting = 1;
            if (mime_out && mime_cap > 0) {
                int m = type_len < mime_cap - 1 ? type_len : mime_cap - 1;
                if (m > 0) memcpy(mime_out, type_ptr, (size_t)m);
                mime_out[m > 0 ? m : 0] = '\0';
            }
            printf("DIME image record #%d: id='%.*s' type='%s' len=%d cf=%d\n",
                   record, id_len, (char*)id_ptr, type_buf[0] ? type_buf : "(none)", data_len, cf);
        }

        if (collecting) {
            memcpy(image + out_len, payload, (size_t)data_len);
            out_len += data_len;
            if (!cf) {
                *image_out = image;
                *image_len_out = out_len;
                return 0;
            }
        }

        pos += data_len + pad4(data_len);
        if (pos <= offset) break;
        offset = pos;
        record++;
    }

    free(image);
    return -4;
}

static int find_jpeg_bounds(const unsigned char *data, int len, int *start_out, int *end_out) {
    int start = -1;
    for (int i = 0; i < len - 2; i++) {
        if (data[i] == 0xFF && data[i + 1] == 0xD8 && data[i + 2] == 0xFF) {
            start = i;
            break;
        }
    }
    if (start < 0) return -1;

    int end = -1;
    for (int i = len - 2; i >= start; i--) {
        if (data[i] == 0xFF && data[i + 1] == 0xD9) {
            end = i + 2;
            break;
        }
    }
    if (end < 0) end = len;

    *start_out = start;
    *end_out = end;
    return 0;
}

void send_soap(libusb_device_handle *h, const char *label, const char *body) {
    char http[8192];
    int blen = strlen(body);
    int hlen = snprintf(http, sizeof(http),
        "POST / HTTP/1.1\r\nHost: localhost\r\nUser-Agent: gSOAP/2.7\r\n"
        "Content-Type: application/soap+xml; charset=utf-8\r\n"
        "Content-Length: %d\r\n\r\n%s", blen, body);
    int xfer;
    libusb_bulk_transfer(h, 0x02, (unsigned char*)http, hlen, &xfer, 5000);
    printf("[%s] sent %d bytes\n", label, xfer); fflush(stdout);
}

int read_response(libusb_device_handle *h, unsigned char *buf, int buf_size) {
    int total = 0, empty = 0;
    for (int i = 0; i < 30; i++) {
        int rx = 0;
        libusb_bulk_transfer(h, 0x82, buf+total, buf_size-total, &rx, 3000);
        if (rx > 0) { total += rx; empty=0; }
        else { empty++; if (empty > 8 && total > 0) break; usleep(50000); }
    }
    if (total < buf_size) buf[total] = 0;
    return total;
}

int main() {
    libusb_context *ctx;
    libusb_init(&ctx);
    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, 0x03f0, 0x222a);
    if (!h) { printf("Device not found\n"); return 1; }
    printf("Device opened\n");
    libusb_set_auto_detach_kernel_driver(h, 1);
    libusb_claim_interface(h, 0);

    unsigned char *buf = malloc(10*1024*1024);
    int n;

    // Step 1: Fresh connection + GetScannerElements
    printf("\n=== Step 1: GetScannerElements ===\n");
    libusb_release_interface(h, 0);
    usleep(500000);
    libusb_claim_interface(h, 0);
    unsigned char dot4[] = {0x00,0x00,0x00,0x08,0x01,0x00,0x00,0x20};
    int xfer;
    libusb_bulk_transfer(h, 0x02, dot4, 8, &xfer, 1000);
    usleep(100000);

    send_soap(h, "GetElements",
        NS "<wscn:GetScannerElements></wscn:GetScannerElements>" NE);
    n = read_response(h, buf, 65536);
    printf("  Response: %d bytes\n", n);

    // Step 2: CreateScanJob (same connection)
    printf("\n=== Step 2: CreateScanJob (RGB24, 300 DPI) ===\n");
    send_soap(h, "CreateJob",
        NS "<wscn:CreateScanJobRequest>"
        "<ScanIdentifier></ScanIdentifier><ScanTicket><JobDescription></JobDescription>"
        "<DocumentParameters><Format>jfif</Format><InputSource>Platen</InputSource>"
        "<InputSize><InputMediaSize><Width>8500</Width><Height>11000</Height></InputMediaSize>"
        "<DocumentSizeAutoDetect>false</DocumentSizeAutoDetect></InputSize>"
        "<MediaSides><MediaFront>"
        "<ScanRegion><ScanRegionXOffset>0</ScanRegionXOffset><ScanRegionYOffset>0</ScanRegionYOffset>"
        "<ScanRegionWidth>8500</ScanRegionWidth><ScanRegionHeight>11000</ScanRegionHeight></ScanRegion>"
        "<Resolution><Width>300</Width><Height>300</Height></Resolution>"
        "<ColorProcessing>RGB24</ColorProcessing>"
        "</MediaFront></MediaSides></DocumentParameters></ScanTicket>"
        "</wscn:CreateScanJobRequest>" NE);
    n = read_response(h, buf, 65536);
    printf("  Response: %d bytes\n", n);

    // Extract JobId
    char job_id[32] = "1";
    char *p = strstr((char*)buf, "<JobId>");
    if (p) { p+=7; char *e=strstr(p,"</"); if(e){int l=e-p; if(l<31){strncpy(job_id,p,l); job_id[l]=0;}} }
    printf("  JobId: %s\n", job_id);

    // Use JobId from Step 2 response (if available), otherwise wait for delayed response
    char real_job_id[32] = "";
    if (job_id[0] && strcmp(job_id, "1") != 0) {
        strcpy(real_job_id, job_id);
        printf("\n  Using JobId from Step 2: %s\n", real_job_id);
    } else {
        // Wait up to 30s for delayed CreateScanJobResponseType
        printf("\n=== Waiting for CreateScanJobResponse (up to 30s) ===\n");
        fflush(stdout);
        int wait_total = 0;
        time_t start = time(NULL);
        while (time(NULL) - start < 30) {
            int rx = 0;
            libusb_bulk_transfer(h, 0x82, buf+wait_total, 65536, &rx, 1000);
            if (rx > 0) {
                wait_total += rx;
                buf[wait_total] = 0;
                char *jid = strstr((char*)buf, "<JobId>");
                if (jid) {
                    jid += 7; char *e = strstr(jid, "</");
                    if (e) { int l=e-jid; if(l<31){strncpy(real_job_id,jid,l); real_job_id[l]=0;} }
                    printf("  Got JobId: %s\n", real_job_id);
                    break;
                }
            }
            usleep(200000);
        }
        if (!real_job_id[0]) { strcpy(real_job_id, "1"); printf("  Fallback JobId: 1\n"); }
    }

    // Wait for user to press ENTER
    printf("\n");
    printf("=====================================================\n");
    printf("  JobId: %s\n", real_job_id);
    printf("  When you see 'HP' blinking → press ENTER here.\n");
    printf("  (Or press ENTER now if scan already completed)\n");
    printf("=====================================================\n");
    printf("\nWaiting for ENTER... "); fflush(stdout);
    getchar();
    printf("GO!\n\n");

    // Step 4: Send RetrieveImage on SAME connection (NO reclaim!)
    int total = 0;
    time_t start;
    printf("=== Step 4: RetrieveImage (same connection, JobId=%s) ===\n", real_job_id);
    char retrieve[2048];
    snprintf(retrieve, sizeof(retrieve),
        NS "<wscn:RetrieveImageRequest>"
        "<JobId>%s</JobId><JobToken>wscn:job:%s</JobToken>"
        "<DocumentDescription></DocumentDescription>"
        "</wscn:RetrieveImageRequest>" NE, real_job_id, real_job_id);
    send_soap(h, "Retrieve", retrieve);

    // Read response for 60s
    int retrieve_total = 0;
    int empty = 0;
    printf("Reading response (60s)...\n"); fflush(stdout);
    start = time(NULL);
    while (time(NULL) - start < 60) {
        int rx = 0;
        libusb_bulk_transfer(h, 0x82, buf+total+retrieve_total, 65536, &rx, 2000);
        if (rx > 0) {
            retrieve_total += rx; empty = 0;
            printf("  [%3lds] +%d = %d\n", time(NULL)-start, rx, retrieve_total);
            fflush(stdout);
        } else {
            empty++;
            if (empty > 30 && retrieve_total > 0) break;
            usleep(100000);
        }
    }
    total += retrieve_total;

    printf("\n=== TOTAL: %d bytes ===\n", total);
    if (total > 100) {
        FILE *f = fopen("papercat_scan_raw.bin","wb"); fwrite(buf,1,total,f); fclose(f);
        printf("Saved papercat_scan_raw.bin\n");

        // Show what we got
        printf("First 300: %.300s\n\n", buf);
        if (strstr((char*)buf,"application/dime")) printf("*** DIME RESPONSE! ***\n");
        if (strstr((char*)buf,"blocked")) printf("SERVICE BLOCKED!\n");
        char *it = strstr((char*)buf,"image/");
        if (it) printf("Image type: %.20s\n", it);
        char *err = strstr((char*)buf,"Error ");
        if (err) printf("Error: %.15s\n", err);

        unsigned char *decoded = NULL;
        int decoded_len = 0;
        int decode_rc = decode_http_chunked_body(buf, total, &decoded, &decoded_len);
        if (decode_rc != 0) {
            printf("Failed to decode chunked HTTP body (code %d)\n", decode_rc);
        } else {
            f = fopen("papercat_scan_decoded.bin", "wb");
            if (f) { fwrite(decoded, 1, (size_t)decoded_len, f); fclose(f); }
            printf(">>> SAVED papercat_scan_decoded.bin (%d bytes) <<<\n", decoded_len);

            unsigned char *image_payload = NULL;
            int image_payload_len = 0;
            char mime_type[64] = {0};

            int dime_rc = extract_image_from_dime(decoded, decoded_len, &image_payload, &image_payload_len, mime_type, (int)sizeof(mime_type));
            if (dime_rc == 0) {
                int jpeg_start = 0;
                int jpeg_end = image_payload_len;
                if (find_jpeg_bounds(image_payload, image_payload_len, &jpeg_start, &jpeg_end) == 0) {
                    int jpeg_len = jpeg_end - jpeg_start;
                    f = fopen("papercat_scan_output.jpg", "wb");
                    if (f) { fwrite(image_payload + jpeg_start, 1, (size_t)jpeg_len, f); fclose(f); }
                    printf(">>> SAVED papercat_scan_output.jpg (%d bytes, %s, offset=%d) <<<\n",
                           jpeg_len, mime_type[0] ? mime_type : "image/unknown", jpeg_start);
                } else {
                    printf("DIME image payload found (%d bytes) but JPEG markers not found\n", image_payload_len);
                }

                // Save raw image payload (before JPEG trimming), useful for comparison/debugging
                f = fopen("papercat_scan_raw_jpeg.bin", "wb");
                if (f) { fwrite(image_payload, 1, (size_t)image_payload_len, f); fclose(f); }
                printf(">>> SAVED papercat_scan_raw_jpeg.bin (%d bytes payload) <<<\n", image_payload_len);
                free(image_payload);
            } else {
                printf("Failed to parse DIME image payload (code %d)\n", dime_rc);

                // Fallback: try extracting JPEG markers from decoded payload directly
                int jpeg_start = 0;
                int jpeg_end = 0;
                if (find_jpeg_bounds(decoded, decoded_len, &jpeg_start, &jpeg_end) == 0) {
                    int jpeg_len = jpeg_end - jpeg_start;
                    f = fopen("papercat_scan_output.jpg", "wb");
                    if (f) { fwrite(decoded + jpeg_start, 1, (size_t)jpeg_len, f); fclose(f); }
                    printf(">>> FALLBACK SAVED papercat_scan_output.jpg (%d bytes, offset=%d) <<<\n", jpeg_len, jpeg_start);
                }
            }

            free(decoded);
        }
    }

    free(buf);
    libusb_release_interface(h, 0);
    libusb_close(h);
    libusb_exit(ctx);
    return 0;
}
