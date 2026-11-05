import rclpy
from rclpy.node import Node

class HelloRos(Node):
    def __init__(self):
        super().__init__('hello_ros')
        self.timer = self.create_timer(1.0, self.tick)
        self.count = 0
    def tick(self):
        self.get_logger().info(f'hi {self.count}')
        self.count += 1

def main():
    rclpy.init()
    node = HelloRos()
    rclpy.spin(node)
    rclpy.shutdown()

if __name__ == '__main__':
    main()

# auto-watch test 11:50:55
