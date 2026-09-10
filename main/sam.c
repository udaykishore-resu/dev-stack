#include <stdio.h>
#include <pthread.h>
#include <unistd.h>

struct ThreadData {
    pthread_t parent_id;
    pthread_t self_id;
};

void* thread_function(void* arg) {
    struct ThreadData* data = (struct ThreadData*)arg;
    data->self_id = pthread_self();
    
    printf("Parent Thread ID: %lu\n", (unsigned long)data->parent_id);
    printf("Current Thread ID: %lu\n", (unsigned long)data->self_id);
    
    return NULL;
}

int main() {
    pthread_t tid;
    struct ThreadData data;
    
    data.parent_id = pthread_self();
    
    pthread_create(&tid, NULL, thread_function, &data);
    pthread_join(tid, NULL);
    
    return 0;
}
